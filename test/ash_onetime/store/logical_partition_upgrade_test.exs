defmodule AshOnetime.Store.LogicalPartitionUpgradeTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.Repo
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
    version = System.unique_integer([:positive])

    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(Repo, ~s(CREATE SCHEMA "#{schema}"), [])
      create_legacy_tables!(schema)
      seed_legacy_rows!(schema)

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
    [
      """
      CREATE TABLE #{relation(schema, "ash_onetime_idempotency_claims")} (
        id uuid PRIMARY KEY,
        operation_hash bytea NOT NULL,
        scope_hash bytea NOT NULL,
        key_hash bytea NOT NULL,
        UNIQUE(operation_hash, scope_hash, key_hash)
      )
      """,
      """
      CREATE TABLE #{relation(schema, "ash_onetime_nonce_claims")} (
        id uuid PRIMARY KEY,
        operation_hash bytea NOT NULL,
        scope_hash bytea NOT NULL,
        key_hash bytea NOT NULL,
        UNIQUE(operation_hash, scope_hash, key_hash)
      )
      """,
      """
      CREATE TABLE #{relation(schema, "ash_onetime_response_payloads")} (
        partition_date date NOT NULL,
        claim_id uuid NOT NULL,
        encoded_response bytea NOT NULL,
        PRIMARY KEY(partition_date, claim_id)
      ) PARTITION BY RANGE(partition_date)
      """,
      """
      CREATE TABLE #{relation(schema, "ash_onetime_response_payloads_default")}
        PARTITION OF #{relation(schema, "ash_onetime_response_payloads")} DEFAULT
      """
    ]
    |> Enum.each(&SQL.query!(Repo, &1, []))
  end

  defp seed_legacy_rows!(schema) do
    locator = [hash("operation"), hash("scope"), hash("key")]
    idempotency_id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_idempotency_claims")}(id,operation_hash,scope_hash,key_hash) VALUES($1::uuid,$2,$3,$4)",
      [Ecto.UUID.dump!(idempotency_id) | locator]
    )

    SQL.query!(
      Repo,
      "INSERT INTO #{relation(schema, "ash_onetime_nonce_claims")}(id,operation_hash,scope_hash,key_hash) VALUES($1::uuid,$2,$3,$4)",
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
      "INSERT INTO #{relation(schema, "ash_onetime_idempotency_claims")}(id,logical_partition,operation_hash,scope_hash,key_hash) SELECT $1::uuid,'tenant-a',operation_hash,scope_hash,key_hash FROM #{relation(schema, "ash_onetime_idempotency_claims")} WHERE logical_partition='global'",
      [Ecto.UUID.dump!(Ecto.UUID.generate())]
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
