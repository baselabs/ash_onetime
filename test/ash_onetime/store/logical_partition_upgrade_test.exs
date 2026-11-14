defmodule AshOnetime.Store.LogicalPartitionUpgradeTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.Repo
  alias AshOnetime.Test.ShippedMigrations
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

  test "renders a reversible upgrade for existing claim installations" do
    source = GenerateMigrations.render_logical_partition_upgrade(Repo, [])

    assert {:ok, _quoted} = Code.string_to_quoted(source)
    assert source =~ "ADD COLUMN logical_partition"
    assert source =~ "DEFAULT 'global'"
    assert source =~ "logical_partition, operation_hash, scope_hash, key_hash"
    assert source =~ "cannot remove logical partitions while non-global claims exist"
  end

  test "backfills global, separates collisions, and refuses a lossy downgrade" do
    unique = Ecto.UUID.generate() |> String.replace("-", "")
    schema = "ash_onetime_upgrade_#{unique}"
    source = GenerateMigrations.render_logical_partition_upgrade(Repo, [])
    module = Module.concat([__MODULE__, "Migration#{unique}"])

    source =
      String.replace(
        source,
        inspect(Repo) <> ".Migrations.AddAshOnetimeLogicalPartitions",
        inspect(module)
      )

    [{^module, _bytecode}] = Code.compile_string(source)
    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(Repo, ~s(CREATE SCHEMA "#{schema}"), [])
      create_legacy_tables!(schema)
      seed_legacy_rows!(schema)
      version = System.unique_integer([:positive, :monotonic])

      assert :ok = Ecto.Migrator.up(Repo, version, module, prefix: schema, log: false)

      assert %{rows: [["global", "global", "global"]]} =
               SQL.query!(
                 Repo,
                 "SELECT (SELECT logical_partition FROM #{relation(schema, "ash_onetime_idempotency_claims")}), (SELECT logical_partition FROM #{relation(schema, "ash_onetime_nonce_claims")}), (SELECT logical_partition FROM #{relation(schema, "ash_onetime_response_payloads")})",
                 []
               )

      insert_partitioned_collision!(schema)

      assert_raise Postgrex.Error,
                   ~r/cannot remove logical partitions while non-global claims exist/,
                   fn ->
                     Ecto.Migrator.down(Repo, version, module, prefix: schema, log: false)
                   end

      SQL.query!(
        Repo,
        "DELETE FROM #{relation(schema, "ash_onetime_idempotency_claims")} WHERE logical_partition='tenant-a'",
        []
      )

      assert :ok = Ecto.Migrator.down(Repo, version, module, prefix: schema, log: false)
      refute "logical_partition" in columns(schema, "ash_onetime_idempotency_claims")
      refute "logical_partition" in columns(schema, "ash_onetime_nonce_claims")
      refute "logical_partition" in columns(schema, "ash_onetime_response_payloads")
    after
      SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE), [])
      Sandbox.mode(Repo, :manual)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp create_legacy_tables!(schema) do
    module = Module.concat(__MODULE__, "Install#{System.unique_integer([:positive])}")
    source = ShippedMigrations.render("v0.6.0", :render, Repo, partition_start: ~D[2000-01-01])

    source =
      String.replace(source, inspect(Repo) <> ".Migrations.InstallAshOnetime", inspect(module))

    Code.compile_string(source)

    try do
      assert :ok =
               Ecto.Migrator.up(Repo, System.unique_integer([:positive, :monotonic]), module,
                 prefix: schema,
                 log: false
               )
    after
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp seed_legacy_rows!(schema) do
    locator = [hash("operation"), hash("scope"), hash("key")]
    idempotency_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_idempotency_claims")}(id,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at) VALUES($1::uuid,$2,$3,$4,$2,'complete',current_date,'fixture',$2,now()-interval '2 days',now()-interval '1 day',now()-interval '2 days')",
      [Ecto.UUID.dump!(idempotency_id) | locator]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_nonce_claims")}(id,operation_hash,scope_hash,key_hash,issued_at,verifier_id,admitted_at,retain_until,inserted_at) VALUES($1::uuid,$2,$3,$4,now(),'fixture',now(),now()+interval '1 day',now())",
      [Ecto.UUID.dump!(Ecto.UUID.generate()) | locator]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_response_payloads")}(partition_date,claim_id,encoded_response) VALUES(current_date,$1::uuid,$2)",
      [Ecto.UUID.dump!(idempotency_id), "response"]
    )
  end

  defp insert_partitioned_collision!(schema) do
    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_idempotency_claims")}(id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at) SELECT $1::uuid,'tenant-a',operation_hash,scope_hash,key_hash,fingerprint,state,response_partition,response_codec,response_digest,admitted_at,retain_until,inserted_at FROM #{relation(schema, "ash_onetime_idempotency_claims")} WHERE logical_partition='global'",
      [Ecto.UUID.dump!(Ecto.UUID.generate())]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) SELECT logical_partition,response_partition,id,'response' FROM #{relation(schema, "ash_onetime_idempotency_claims")} WHERE logical_partition='tenant-a'",
      []
    )
  end

  defp columns(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 ORDER BY column_name",
        [schema, table]
      )

    List.flatten(rows)
  end

  defp relation(schema, table), do: ~s("#{schema}"."#{table}")
  defp hash(value), do: :crypto.hash(:sha256, value)
end
