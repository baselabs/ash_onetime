defmodule AshOnetime.Store.OperationHoldUpgradeTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  @moduletag timeout: 180_000

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "operation-hold generator mode renders a standalone concurrent upgrade" do
    directory = Path.join(System.tmp_dir!(), "hold_upgrade_#{System.unique_integer([:positive])}")

    try do
      path =
        Generator.run([
          "--repo",
          inspect(Repo),
          "--operation-hold",
          "--migrations-path",
          directory
        ])

      source = File.read!(path)
      assert source =~ "@disable_ddl_transaction true"
      assert source =~ "@disable_migration_lock true"
      assert source =~ "CONCURRENTLY"
      assert source =~ "NOT VALID"
      assert source =~ "VALIDATE CONSTRAINT"
      assert source =~ "ATTACH PARTITION"
      assert source =~ "indisvalid"
    after
      File.rm_rf!(directory)
    end
  end

  for claims <- [:plain, :hash] do
    @claims claims
    test "operation-hold upgrade preserves data and supports down/up on #{@claims} claims" do
      {schema, unique} = install_legacy!(@claims)
      unique = unique + 1
      module = Module.concat(__MODULE__, "Upgrade#{unique}")
      source = Generator.render_operation_hold_upgrade(Repo, [])

      source =
        String.replace(
          source,
          inspect(Repo) <> ".Migrations.AddAshOnetimeOperationHold",
          inspect(module)
        )

      Code.compile_string(source)
      Sandbox.mode(Repo, :auto)

      try do
        id = Ecto.UUID.bingenerate()

        for {claim_id, key} <- [{id, "first"}, {Ecto.UUID.bingenerate(), "second"}] do
          SQL.query!(
            Repo,
            ~s|INSERT INTO "#{schema}".ash_onetime_idempotency_claims (id, operation_hash, scope_hash, key_hash, fingerprint, state, response_partition, response_codec, response_digest, admitted_at, retain_until, inserted_at) VALUES ($1, $2, $2, $3, $2, 'complete', current_date, 'test', $4, now(), now() + interval '1 hour', now())|,
            [
              claim_id,
              :crypto.hash(:sha256, "existing"),
              :crypto.hash(:sha256, key),
              :crypto.hash(:sha256, "response")
            ]
          )

          SQL.query!(
            Repo,
            ~s|INSERT INTO "#{schema}".ash_onetime_response_payloads (partition_date, claim_id, encoded_response) VALUES (current_date, $1, $2)|,
            [claim_id, "response"]
          )
        end

        if @claims == :plain do
          assert_raise Postgrex.Error, ~r/unique index/, fn ->
            SQL.query!(
              Repo,
              ~s|CREATE UNIQUE INDEX CONCURRENTLY ash_onetime_idempotency_claims_cleanup_index ON "#{schema}".ash_onetime_idempotency_claims (state)|,
              []
            )
          end

          assert %{rows: [[false]]} =
                   SQL.query!(
                     Repo,
                     "SELECT indisvalid FROM pg_index WHERE indexrelid = $1::text::regclass",
                     [schema <> ".ash_onetime_idempotency_claims_cleanup_index"]
                   )
        end

        assert :ok = Ecto.Migrator.up(Repo, unique, module, prefix: schema, log: false)

        assert %{rows: [[nil]]} =
                 SQL.query!(
                   Repo,
                   ~s|SELECT hold_reference FROM "#{schema}".ash_onetime_idempotency_claims WHERE id = $1|,
                   [id]
                 )

        assert %{rows: rows} =
                 SQL.query!(
                   Repo,
                   "SELECT i.indisvalid FROM pg_index i WHERE i.indexrelid IN (SELECT indexrelid FROM pg_index WHERE indrelid = $1::text::regclass) AND pg_get_indexdef(i.indexrelid) LIKE '%hold_reference%'",
                   [schema <> ".ash_onetime_idempotency_claims"]
                 )

        assert rows == [[true], [true]]

        assert %{rows: [[2]]} =
                 SQL.query!(
                   Repo,
                   ~s|SELECT count(*) FROM "#{schema}".ash_onetime_response_payloads WHERE encoded_response = $1|,
                   ["response"]
                 )

        SQL.query!(
          Repo,
          ~s|UPDATE "#{schema}".ash_onetime_idempotency_claims SET hold_reference = 'operation' WHERE id = $1|,
          [id]
        )

        SQL.query!(
          Repo,
          ~s|UPDATE "#{schema}".ash_onetime_idempotency_claims SET admitted_at = now() - interval '2 hours', inserted_at = now() - interval '2 hours', retain_until = now() - interval '1 hour'|,
          []
        )

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   assert {:error,
                           %Postgrex.Error{postgres: %{code: :check_violation, message: message}}} =
                            SQL.query(
                              Repo,
                              ~s|DELETE FROM "#{schema}".ash_onetime_idempotency_claims WHERE id = $1|,
                              [id],
                              mode: :savepoint
                            )

                   assert message =~ "held idempotency claim"
                   :ok
                 end)

        # This fixture is still a 1.x install: exercise its invoker directly.
        # The 2.0 Store addresses the dedicated schema after maintenance upgrade.
        assert %{rows: [[1]]} =
                 SQL.query!(
                   Repo,
                   ~s|SELECT "#{schema}".ash_onetime_cleanup_idempotency(100::integer)|,
                   []
                 )

        assert_raise Postgrex.Error, ~r/release operation holds/, fn ->
          Ecto.Migrator.down(Repo, unique, module, prefix: schema, log: false)
        end

        SQL.query!(
          Repo,
          ~s|ALTER TABLE "#{schema}".ash_onetime_idempotency_claims ENABLE ROW LEVEL SECURITY|,
          []
        )

        SQL.query!(
          Repo,
          ~s|ALTER TABLE "#{schema}".ash_onetime_idempotency_claims FORCE ROW LEVEL SECURITY|,
          []
        )

        %{rows: [[bypasses_row_security]]} =
          SQL.query!(
            Repo,
            "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user",
            []
          )

        refusal =
          if bypasses_row_security,
            do: ~r/release operation holds/,
            else: ~r/row-level security/

        assert_raise Postgrex.Error, refusal, fn ->
          Ecto.Migrator.down(Repo, unique, module, prefix: schema, log: false)
        end

        SQL.query!(
          Repo,
          ~s|ALTER TABLE "#{schema}".ash_onetime_idempotency_claims NO FORCE ROW LEVEL SECURITY|,
          []
        )

        assert {:ok, {:ok, 1}} =
                 Repo.transaction(fn ->
                   AshOnetime.Transaction.release(Repo,
                     prefix: schema,
                     partition: "global",
                     reference: "operation"
                   )
                 end)

        assert :ok = Ecto.Migrator.down(Repo, unique, module, prefix: schema, log: false)
        assert :ok = Ecto.Migrator.up(Repo, unique, module, prefix: schema, log: false)
      after
        :code.purge(module)
        :code.delete(module)
      end
    end
  end

  test "store code on an installation without the upgrade refuses admission instead of proceeding" do
    {schema, _version} = install_legacy!(:plain)

    result =
      try do
        Repo.transaction(fn ->
          AshOnetime.Transaction.idempotency(Repo,
            operation: {__MODULE__, :unmigrated},
            prefix: schema,
            partition: "global",
            scope: "scope",
            key: "unmigrated",
            fingerprint: :crypto.hash(:sha256, "request"),
            retention_seconds: 86_400,
            codec: "test"
          )
        end)
      rescue
        error -> {:raised, error}
      end

    refute match?({:ok, {:execute, _admission}}, result),
           "an unmigrated installation must never admit: #{inspect(result)}"

    assert match?({:ok, {:error, %AshOnetime.Error{code: :store_invariant}}}, result) or
             match?({:error, _reason}, result),
           "expected a refusal, got: #{inspect(result)}"

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               ~s|SELECT count(*) FROM "#{schema}".ash_onetime_idempotency_claims|,
               []
             )
  end

  defp install_legacy!(claims) do
    schema = "ash_onetime_upgrade_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
    version = System.unique_integer([:positive])
    module = Module.concat(__MODULE__, "Legacy#{version}")
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
      :code.purge(module)
      :code.delete(module)
    end)

    source =
      EEx.eval_file("test/support/fixtures/idempotency_install.exs.eex",
        module: module,
        collision_constraint: "UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)",
        cleanup_comparator: ">",
        cleanup_delete_predicate:
          "claims.logical_partition = candidates.logical_partition AND claims.operation_hash = candidates.operation_hash AND claims.id = candidates.id",
        hash_partitions: if(claims == :hash, do: 4),
        response_partitions: []
      )

    Code.compile_string(source)
    assert :ok = Ecto.Migrator.up(Repo, version, module, prefix: schema, log: false)
    {schema, version}
  end
end
