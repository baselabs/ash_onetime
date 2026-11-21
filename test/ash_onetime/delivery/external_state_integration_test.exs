for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.Delivery.ExternalStateIntegrationTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    import AshOnetime.Test.DeliveryCase
    import ExUnit.CaptureIO
    alias AshOnetime.Delivery
    alias AshOnetime.Test.ExitBoundary.{Faults, Pair, Withheld}
    alias AshOnetime.Test.ExitBoundary.Pair.Path
    alias AshOnetime.Test.ExternalPeer
    @moduletag hash_partitions: partitioning
    @moduletag :delivery_external_state_integration

    setup_all c do
      previous = Repo.put_dynamic_repo(c.owner_repo)

      try do
        ExternalPeer.install!(c.schema)

        SQL.query!(
          c.owner_repo,
          "CREATE TABLE #{rel(c, "ash_onetime_boundary_records")} (id uuid PRIMARY KEY, amount bigint NOT NULL, retired boolean NOT NULL DEFAULT false)",
          []
        )
      after
        Repo.put_dynamic_repo(previous)
      end

      :ok
    end

    setup c do
      SQL.query!(
        Repo,
        "TRUNCATE #{rel(c, "external_peer_calls")},#{rel(c, "external_peer_operations")},#{rel(c, "external_peer_effects")},#{rel(c, "external_local_effects")}",
        []
      )

      peer = start_supervised!({Postgrex, ExternalPeer.database_options()})
      Faults.put_peer(peer)
      Faults.put(nil)
      Faults.plant(:crypto.strong_rand_bytes(8), :crypto.strong_rand_bytes(32))
      previous = Repo.put_dynamic_repo(c.runtime_repo)
      on_exit(fn -> Repo.put_dynamic_repo(previous) end)
      :ok
    end

    for action <- [
          :external_issue,
          :external_rotate,
          :external_revoke,
          :external_retire,
          :external_mint
        ] do
      @action action
      test "#{partitioning || "plain"}: #{@action}: a rolled-back delivered completion survives all maintenance and refuses rollback",
           c do
        build = builder(c, @action)
        Process.put(:delivery_rollback, true)
        first = build.() |> fail_after_completion(:delivery_rollback) |> AshOnetime.deliver()
        assert match?({:error, _}, first)
        refute Process.get(:delivery_rollback)
        [[id, 1, "processing"]] = claims(c)
        age_claim(c, id)

        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_reap_idempotency", "100,86400")
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_expire_responses", "100")
        assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")
        assert {:ok, _} = step(c, "ash_onetime_prune_payload_partitions", "100,1000")
        assert {:ok, _} = step(c, "ash_onetime_roll_payload_partitions", "2")
        assert [[^id, 1, "processing"]] = claims(c)

        previous = Repo.put_dynamic_repo(c.owner_repo)

        refusal =
          try do
            Ecto.Migrator.down(Repo, 20_261_116_000_001, c.migration_module,
              prefix: c.schema,
              log: false
            )
          rescue
            error in Postgrex.Error -> {:error, error}
          after
            Repo.put_dynamic_repo(previous)
          end

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = refusal

        assert scalar(c.owner_repo, "SELECT to_regclass($1) IS NOT NULL", [
                 rel(c, "ash_onetime_external_state_restore")
               ])

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
                 SQL.query(
                   c.runtime_repo,
                   "SELECT * FROM #{rel(c, "ash_onetime_external_state_restore")}",
                   []
                 )

        output =
          capture_io(fn ->
            Mix.Tasks.AshOnetime.Doctor.run([
              "--repo",
              inspect(Repo),
              "--live",
              "--prefix",
              c.schema
            ])
          end)

        assert output =~ "unresolved: 1"

        retry = AshOnetime.deliver(build.())
        assert %Delivery{outcome: :recovered, values: %{}} = elem(retry, tuple_size(retry) - 1)
        assert [[^id, 2, "complete"]] = claims(c)
        assert peer_counts(c) == {1, 1, 1}
        assert_at_most_one_value([first, retry])
      end

      @tag :delivery_completion_attempt
      test "#{partitioning || "plain"}: #{@action}: a later attempt cannot authorize an earlier rolled-back envelope",
           c do
        build = builder(c, @action)
        Process.put(:delivery_attempt_rollback, true)

        first =
          build.()
          |> fail_after_completion(:delivery_attempt_rollback)
          |> hook(
            :after_transaction,
            fn
              input, {:error, _} ->
                retry = AshOnetime.deliver(build.())
                Process.put(:delivery_later_attempt, retry)

                # A destroy's public return omits the record. Its transaction
                # hook still owes Ash the record before that return is shaped.
                result =
                  case input do
                    %Ash.Changeset{action_type: :destroy, data: record} -> record
                    _other -> elem(retry, 1)
                  end

                {:ok, result}

              _input, result ->
                result
            end,
            []
          )
          |> AshOnetime.deliver()

        retry = Process.delete(:delivery_later_attempt)
        assert %Delivery{outcome: :recovered, values: %{}} = elem(retry, tuple_size(retry) - 1)
        assert error_code(first) == :executing_only_lost
        assert [[_, 2, "complete"]] = claims(c)
        assert peer_counts(c) == {1, 1, 1}
        assert_at_most_one_value([first, retry])
      end
    end

    for action <- [
          :issue,
          :rotate,
          :revoke,
          :retire,
          :mint,
          :external_issue,
          :external_rotate,
          :external_revoke,
          :external_retire,
          :external_mint
        ] do
      @action action
      test "#{partitioning || "plain"}: #{@action} opens its committed envelope after response expiry without replaying values",
           c do
        build = builder(c, @action)

        first =
          build.()
          |> hook(
            :after_transaction,
            fn _input, result ->
              [[id, _, "complete"]] = claims(c)
              age_claim(c, id, retain: "transaction_timestamp()+interval '1 day'")
              assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_expire_responses", "100")
              assert {:ok, %{rows: [[0]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")
              assert {:ok, _} = step(c, "ash_onetime_prune_payload_partitions", "100,1000")
              result
            end,
            []
          )
          |> AshOnetime.deliver()

        assert %Delivery{outcome: :executed, values: values} = elem(first, tuple_size(first) - 1)
        assert map_size(values) == 2
        assert length(delivered(first)) == 1
        assert error_code(AshOnetime.deliver(build.())) == :response_expired
      end

      test "#{partitioning || "plain"}: #{@action} refuses an envelope whose completed claim cleanup removed before OPEN",
           c do
        build = builder(c, @action)

        first =
          build.()
          |> hook(
            :after_transaction,
            fn _input, result ->
              [[id, _, "complete"]] = claims(c)
              age_claim(c, id)
              assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_expire_responses", "100")
              assert {:ok, %{rows: [[1]]}} = step(c, "ash_onetime_cleanup_idempotency", "100")
              result
            end,
            []
          )
          |> AshOnetime.deliver()

        assert error_code(first) == :executing_only_lost
        assert claims(c) == []
      end
    end

    defp builder(c, action) do
      {type, input, record?} =
        case action do
          a when a in [:issue, :external_issue] ->
            {:create, %{amount: 7}, false}

          a when a in [:rotate, :external_rotate] ->
            {:update, %{amount: 7}, true}

          a when a in [:revoke, :external_revoke, :retire, :external_retire] ->
            {:destroy, %{}, true}

          a when a in [:mint, :external_mint] ->
            {:action, %{value: 7}, false}
        end

      record = if record?, do: Pair.seed!(Withheld, c.schema)
      path = %Path{type: type, action: action, key: unique_key("durable-delivery"), input: input}
      fn -> Pair.subject(path, Withheld, c.schema, record) end
    end

    defp claims(c),
      do:
        SQL.query!(
          c.runtime_repo,
          "SELECT id::text,effect_attempt,state FROM #{rel(c, "ash_onetime_idempotency_claims")} ORDER BY id",
          []
        ).rows

    defp peer_counts(c) do
      [[executed, recovered, effects]] =
        Postgrex.query!(
          Faults.peer(),
          "SELECT (SELECT count(*) FROM #{rel(c, "external_peer_calls")} WHERE kind='execute'),(SELECT count(*) FROM #{rel(c, "external_peer_calls")} WHERE kind='recover'),(SELECT count(*) FROM #{rel(c, "external_peer_effects")})",
          []
        ).rows

      {executed, recovered, effects}
    end
  end
end
