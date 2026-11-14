defmodule AshOnetime.Store.PruneSchemaTest do
  use AshOnetime.Test.StoreCase, async: false

  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  for explicit_prefix? <- [false, true] do
    @explicit_prefix explicit_prefix?
    test "prune resolves the parent's namespace with explicit prefix #{@explicit_prefix}", ctx do
      schema = if @explicit_prefix, do: ctx.prefix, else: "public"

      unless @explicit_prefix, do: install_public!()

      %{rows: [[user]]} = SQL.query!(Repo, "SELECT current_user", [])
      SQL.query!(Repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{user}"), [])

      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1",
                 [user]
               )

      SQL.query!(Repo, ~s(SET LOCAL search_path = "$user", public), [])
      assert %{rows: [[^user]]} = SQL.query!(Repo, "SELECT current_schema()", [])

      SQL.query!(
        Repo,
        ~s|CREATE TABLE "#{schema}"."ash_onetime_response_payloads_2001_01" PARTITION OF "#{schema}"."ash_onetime_response_payloads" FOR VALUES FROM ('2001-01-01') TO ('2001-02-01')|,
        []
      )

      SQL.query!(
        Repo,
        ~s|SELECT "#{schema}".ash_onetime_maintenance_copy_policy($1::text::regclass)|,
        [schema <> ".ash_onetime_response_payloads_2001_01"]
      )

      target = Postgres.for_repo(Repo, if(@explicit_prefix, do: schema))
      assert {:ok, %{payload_partitions: 1}} = Store.cleanup(target, 100, 10)

      assert %{rows: [[nil]]} =
               SQL.query!(Repo, "SELECT to_regclass($1)", [
                 schema <> ".ash_onetime_response_payloads_2001_01"
               ])
    end
  end

  test "the DEFAULT drain resolves its parent namespace behind an empty user schema" do
    install_public!()
    %{rows: [[user]]} = SQL.query!(Repo, "SELECT current_user", [])
    SQL.query!(Repo, ~s|CREATE SCHEMA IF NOT EXISTS "#{user}"|, [])
    SQL.query!(Repo, ~s|SET LOCAL search_path = "$user", public|, [])
    assert %{rows: [[^user]]} = SQL.query!(Repo, "SELECT current_schema()", [])

    for {label, hold} <- [{"expired", nil}, {"held", "operation"}] do
      id = Ecto.UUID.bingenerate()
      hash = :crypto.hash(:sha256, label)

      SQL.query!(
        Repo,
        """
        INSERT INTO public.ash_onetime_idempotency_claims
          (id, operation_hash, scope_hash, key_hash, fingerprint, state, response_partition,
           response_codec, response_digest, hold_reference, admitted_at, retain_until, inserted_at)
        VALUES ($1, $2, $2, $2, $2, 'complete', '2100-01-01', 'test', $2, $3,
                now() - interval '2 days', now() - interval '1 day', now() - interval '2 days')
        """,
        [id, hash, hold]
      )

      SQL.query!(
        Repo,
        "INSERT INTO public.ash_onetime_response_payloads (partition_date, claim_id, encoded_response) VALUES ('2100-01-01', $1, $2)",
        [id, "response"]
      )
    end

    assert {:ok, _} = Store.roll_partitions(Postgres.for_repo(Repo, "public"), 1)
    assert {:ok, _} = Store.cleanup(Postgres.for_repo(Repo, "public"), 100, 0)

    assert %{rows: [[1, "operation"]]} =
             SQL.query!(
               Repo,
               "SELECT count(*), min(hold_reference) FROM public.ash_onetime_idempotency_claims",
               []
             )

    assert %{rows: [[1]]} =
             SQL.query!(Repo, "SELECT count(*) FROM public.ash_onetime_response_payloads", [])

    assert %{rows: [[true]]} =
             SQL.query!(
               Repo,
               "SELECT to_regclass('public.ash_onetime_response_payloads_2100_01') IS NOT NULL",
               []
             )
  end

  defp install_public!,
    do: run_sql_migration!(Generator.render(Repo, []), "InstallAshOnetime", "public")

  defp run_sql_migration!(source, name, prefix) do
    module = Module.concat(__MODULE__, name)
    Process.put({module, :prefix}, prefix)

    source =
      source
      |> String.replace(inspect(Repo) <> ".Migrations." <> name, inspect(module))
      |> String.replace(
        "use Ecto.Migration",
        "def prefix, do: Process.get({__MODULE__, :prefix})\n def repo, do: AshOnetime.Test.Repo\n def execute(sql), do: Ecto.Adapters.SQL.query!(AshOnetime.Test.Repo, sql, [])"
      )

    Code.compile_string(source)

    try do
      module.up()
    after
      Process.delete({module, :prefix})
      :code.purge(module)
      :code.delete(module)
    end
  end
end
