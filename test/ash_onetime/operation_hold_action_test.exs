defmodule AshOnetime.OperationHoldActionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Changes.ReleaseHold
  alias AshOnetime.Transaction

  alias AshOnetime.Test.ExternalPeer
  alias AshOnetime.Test.HoldExamples.{Operation, Settlement}

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup ctx do
    SQL.query!(
      Repo,
      ~s|CREATE TABLE IF NOT EXISTS "#{ctx.prefix}".hold_operations (id uuid PRIMARY KEY, reference text NOT NULL, open boolean NOT NULL)|,
      []
    )

    SQL.query!(
      Repo,
      ~s|CREATE TABLE IF NOT EXISTS "#{ctx.prefix}".hold_settlements (id uuid PRIMARY KEY, reference text NOT NULL)|,
      []
    )

    :ok
  end

  test "the DSL holds an open outcome and ReleaseHold derives the protected resource target",
       ctx do
    reference = Ecto.UUID.generate()
    assert {:ok, record} = open(ctx.prefix, reference)
    assert held_count(ctx.prefix, reference) == 1
    assert {:ok, replay} = open(ctx.prefix, reference)
    assert replay.id == record.id

    for action <- [:settle, :settle_function] do
      reference = Ecto.UUID.generate()
      assert {:ok, _} = open(ctx.prefix, reference)
      assert held_count(ctx.prefix, reference) == 1
      assert {:ok, _} = settle(ctx.prefix, reference, action)
      assert held_count(ctx.prefix, reference) == 0
    end
  end

  test "ReleaseHold defaults to the settling resource's installation", ctx do
    reference = Ecto.UUID.generate()
    assert {:ok, record} = open(ctx.prefix, reference)

    assert {:ok, _} =
             record |> Ash.Changeset.for_update(:settle, %{}, tenant: ctx.prefix) |> Ash.update()

    assert held_count(ctx.prefix, reference) == 0
  end

  test "invalid hold callback references, outcomes, and exceptions are typed and roll back",
       ctx do
    for reference <- ["invalid-reference", "invalid-outcome", "invalid-callback"] do
      assert {:error, error} = open(ctx.prefix, reference)
      assert AshOnetime.Error.code(error) == :invalid_request
      assert held_count(ctx.prefix, reference) == 0
    end

    assert %{rows: [[0]]} =
             SQL.query!(Repo, ~s|SELECT count(*) FROM "#{ctx.prefix}".hold_operations|, [])
  end

  test "a Hold module returning none completes unheld and cleanup removes it at retention", ctx do
    reference = Ecto.UUID.generate()
    assert {:ok, _} = open(ctx.prefix, reference, false)
    assert held_count(ctx.prefix, reference) == 0

    SQL.query!(
      Repo,
      ~s|UPDATE "#{ctx.prefix}".ash_onetime_idempotency_claims SET admitted_at = now() - interval '2 hours', inserted_at = now() - interval '2 hours', retain_until = now() - interval '1 hour' WHERE admitted_at = transaction_timestamp()|,
      []
    )

    assert {:ok, %{idempotency: 1}} = Store.cleanup(ctx.target, 100)
  end

  test "action writes, completion, and hold roll back together; settling rollback keeps the hold",
       ctx do
    reference = Ecto.UUID.generate()

    claim_count =
      SQL.query!(
        Repo,
        ~s|SELECT count(*) FROM "#{ctx.prefix}".ash_onetime_idempotency_claims|,
        []
      ).rows

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = open(ctx.prefix, reference)
               assert held_count(ctx.prefix, reference) == 1
               Repo.rollback(:abort)
             end)

    assert held_count(ctx.prefix, reference) == 0

    assert SQL.query!(
             Repo,
             ~s|SELECT count(*) FROM "#{ctx.prefix}".ash_onetime_idempotency_claims|,
             []
           ).rows == claim_count

    assert %{rows: [[0]]} =
             SQL.query!(Repo, ~s|SELECT count(*) FROM "#{ctx.prefix}".hold_operations|, [])

    assert {:ok, _} = open(ctx.prefix, reference)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = settle(ctx.prefix, reference)
               assert held_count(ctx.prefix, reference) == 0
               Repo.rollback(:abort)
             end)

    assert held_count(ctx.prefix, reference) == 1

    assert %{rows: [[0]]} =
             SQL.query!(Repo, ~s|SELECT count(*) FROM "#{ctx.prefix}".hold_settlements|, [])
  end

  @tag unboxed: true
  test "settling cannot release a hold written by an admitting action before its transaction commits",
       ctx do
    # DDL from setup was unboxed, so both independent connections can see the action tables.
    reference = Ecto.UUID.generate()
    repo = start_unboxed_repo!()
    parent = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(fn ->
          assert {:ok, _} = open(ctx.prefix, reference)
          assert held_count(ctx.prefix, reference, repo) == 1
          send(parent, :hold_written)

          receive do
            :commit -> :ok
          after
            15_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    try do
      assert_receive :hold_written, 15_000

      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 ~s|SELECT count(*) FROM "#{ctx.prefix}".hold_operations WHERE reference = $1|,
                 [reference]
               )

      assert {:ok, _} = settle(ctx.prefix, reference)
      assert held_count(ctx.prefix, reference) == 0
      assert {:ok, {:ok, 0}} = release(ctx.prefix, reference)
      send(task.pid, :commit)
      assert {:ok, :ok} = Task.await(task, 15_000)
      assert held_count(ctx.prefix, reference) == 1

      assert %{rows: [[1]]} =
               SQL.query!(
                 Repo,
                 ~s|SELECT count(*) FROM "#{ctx.prefix}".hold_operations WHERE reference = $1|,
                 [reference]
               )

      assert %{rows: [[1]]} =
               SQL.query!(
                 Repo,
                 ~s|SELECT count(*) FROM "#{ctx.prefix}".ash_onetime_idempotency_claims WHERE hold_reference = $1 AND state = 'complete'|,
                 [reference]
               )

      assert {:ok, {:ok, 1}} = release(ctx.prefix, reference)
    after
      send(task.pid, :commit)
      Task.shutdown(task)

      SQL.query!(Repo, ~s|DELETE FROM "#{ctx.prefix}".hold_operations WHERE reference = $1|, [
        reference
      ])

      SQL.query!(Repo, ~s|DELETE FROM "#{ctx.prefix}".hold_settlements WHERE reference = $1|, [
        reference
      ])
    end
  end

  @tag unboxed: true
  test "the DSL external completion persists its operation hold and replays", ctx do
    reference = Ecto.UUID.generate()
    ExternalPeer.install!(ctx.prefix)
    repo = start_unboxed_repo!()
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    action = fn ->
      Operation
      |> Ash.Changeset.for_create(:external_open, %{reference: reference, request_key: reference},
        tenant: ctx.prefix
      )
      |> Ash.create()
    end

    try do
      assert {:ok, first} = action.()
      assert held_count(ctx.prefix, reference) == 1
      assert {:ok, replay} = action.()
      assert first.id == replay.id

      assert %{rows: [[1]]} =
               SQL.query!(
                 Repo,
                 ~s|SELECT count(*) FROM "#{ctx.prefix}".external_peer_effects|,
                 []
               )

      assert {:ok, {:ok, 1}} = release(ctx.prefix, reference)
    after
      Repo.put_dynamic_repo(previous)

      SQL.query!(Repo, ~s|DELETE FROM "#{ctx.prefix}".hold_operations WHERE reference = $1|, [
        reference
      ])
    end
  end

  test "ReleaseHold rejects a free-form partition option" do
    assert {:error, _} =
             ReleaseHold.init(reference: :reference, partition: "drift")
  end

  test "the transformer rejects a hold module without reference/2" do
    resource = Module.concat(__MODULE__, "InvalidHold")

    assert_raise Spark.Error.DslError, ~r/hold.*reference\/2/s, fn ->
      Code.compile_string("""
      defmodule #{inspect(resource)} do
        use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer, extensions: [AshOnetime.Resource]
        postgres do
          table "invalid_hold"
          repo AshOnetime.Test.Repo
        end
        attributes do
          uuid_primary_key :id
        end
        actions do
          create :open do
            argument :request_key, :string
          end
        end
        onetime do
          protect :open do
            strategy :idempotency
            scope [{:static, "operations"}]
            key {:client, :request_key}
            fingerprint arguments: [:request_key]
            response AshOnetime.Codec.Resource, fields: [:id], classify: AshOnetime.Test.Support.ResponseClassifier
            retention {1, :hour}
            hold String
          end
        end
      end
      """)
    end
  end

  defp open(prefix, reference, open? \\ true),
    do:
      Operation
      |> Ash.Changeset.for_create(
        :open,
        %{reference: reference, open: open?, request_key: reference},
        tenant: prefix
      )
      |> Ash.create()

  defp settle(prefix, reference, action \\ :settle),
    do:
      Settlement
      |> Ash.Changeset.for_create(action, %{reference: reference}, tenant: prefix)
      |> Ash.create()

  defp held_count(prefix, reference, repo \\ Repo),
    do:
      SQL.query!(
        repo,
        ~s|SELECT count(*) FROM "#{prefix}".ash_onetime_idempotency_claims WHERE hold_reference = $1|,
        [reference]
      ).rows
      |> hd()
      |> hd()

  defp release(prefix, reference),
    do:
      Repo.transaction(fn ->
        Transaction.release(Repo, prefix: prefix, partition: "global", reference: reference)
      end)
end
