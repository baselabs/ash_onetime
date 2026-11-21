defmodule AshOnetime.Test.CatalogInventory do
  @moduledoc false
  import AshOnetime.Test.ExternalStateCase
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  def from_templates!(c) do
    suffix = String.replace(Ecto.UUID.generate(), "-", "")
    schema = "ao_inventory_#{suffix}"
    module_name = "AshOnetime.Test.CatalogInstall#{suffix}"

    ExUnit.Callbacks.on_exit(fn ->
      SQL.query!(c.owner_repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE", [])

      SQL.query!(
        c.owner_repo,
        "DROP SCHEMA IF EXISTS #{q(Postgres.routine_schema(schema))} CASCADE",
        []
      )

      module = Module.concat([module_name])
      :code.purge(module)
      :code.delete(module)
    end)

    SQL.query!(c.owner_repo, "CREATE SCHEMA #{q(schema)} AUTHORIZATION #{q(c.owner)}", [])

    SQL.query!(
      c.owner_repo,
      "GRANT USAGE ON SCHEMA #{q(schema)} TO #{q(c.runtime)},#{q(c.maintainer)}",
      []
    )

    SQL.query!(
      c.owner_repo,
      "ALTER DEFAULT PRIVILEGES IN SCHEMA #{q(schema)} GRANT ALL ON TABLES TO #{q(c.runtime)}",
      []
    )

    source =
      Generator.render(Repo, maintenance_role: c.maintainer, hash_partitions: c[:hash_partitions])
      |> String.replace("AshOnetime.Test.Repo.Migrations.InstallAshOnetime", module_name)

    [{module, _}] = Code.compile_string(source)
    :ok = install(%{c | schema: schema, migration_module: module})
    :ok = install_facts!(%{c | schema: schema})
    read(%{c | schema: schema})
  end

  def install_facts!(c) do
    module_name = "AshOnetime.Test.CatalogFacts#{System.unique_integer([:positive])}"

    source =
      Generator.render_fact_tables(Repo, fact_tables: ["inventory_facts"])
      |> String.replace("AshOnetime.Test.Repo.Migrations.AddAshOnetimeBoundaryFacts", module_name)

    [{module, _}] = Code.compile_string(source)

    ExUnit.Callbacks.on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      Ecto.Migrator.up(Repo, 20_261_116_000_002, module, prefix: c.schema, log: false)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  def read(c) do
    relations =
      "SELECT oid FROM pg_class WHERE relnamespace=to_regnamespace($1) AND relname<>'schema_migrations' AND relkind IN ('r','p','S')"

    queries = %{
      constraints: """
      SELECT r.relname,k.conname,k.contype::text,k.condeferrable,k.condeferred,k.convalidated,k.conenforced,
        pg_get_constraintdef(k.oid,true)
      FROM pg_constraint k JOIN pg_class r ON r.oid=k.conrelid
      WHERE k.conrelid IN (#{relations}) AND k.contype IN ('c','p','f')
      """,
      triggers: """
      SELECT r.relname,CASE WHEN t.tgisinternal THEN p.proname ELSE t.tgname END,
        t.tgtype,t.tgenabled::text,t.tgisinternal,n.nspname,p.proname,
        t.tgdeferrable,t.tginitdeferred,encode(t.tgargs,'hex'),t.tgattr::text,
        pg_get_expr(t.tgqual,t.tgrelid,true),t.tgparentid<>0
      FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid
      JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE t.tgrelid IN (#{relations})
      """,
      policies: """
      SELECT r.relname,p.polname,p.polcmd::text,p.polpermissive,
        ARRAY(SELECT CASE WHEN role_oid=0 THEN 'PUBLIC' ELSE pg_get_userbyid(role_oid) END
          FROM unnest(p.polroles)role_oid ORDER BY 1),
        pg_get_expr(p.polqual,p.polrelid,true),pg_get_expr(p.polwithcheck,p.polrelid,true)
      FROM pg_policy p JOIN pg_class r ON r.oid=p.polrelid WHERE p.polrelid IN (#{relations})
      """,
      routines: """
      SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid),p.prosecdef,
        ARRAY(SELECT x FROM unnest(p.proconfig)x ORDER BY x),pg_get_userbyid(p.proowner)
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.oid=to_regnamespace($1) OR n.oid=to_regnamespace($2)
      """,
      table_acls: """
      SELECT r.relname,pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type,a.is_grantable
      FROM pg_class r CROSS JOIN LATERAL aclexplode(coalesce(r.relacl,acldefault(CASE WHEN r.relkind='S' THEN 's'::\"char\" ELSE 'r'::\"char\" END,r.relowner)))a
      WHERE r.oid IN (#{relations})
      """,
      column_acls: """
      SELECT r.relname,c.attname,pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
        a.privilege_type,a.is_grantable
      FROM pg_class r JOIN pg_attribute c ON c.attrelid=r.oid
      CROSS JOIN LATERAL aclexplode(c.attacl)a WHERE r.oid IN (#{relations}) AND c.attnum>0 AND NOT c.attisdropped
      """
    }

    Map.new(queries, fn {kind, sql} ->
      params =
        if kind == :routines, do: [c.schema, Postgres.routine_schema(c.schema)], else: [c.schema]

      rows =
        SQL.query!(c.owner_repo, sql, params).rows |> Enum.map(&normalize(&1, c)) |> Enum.sort()

      {kind, rows}
    end)
  end

  def with_drift(c, kind, assertion) do
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      {:error, :inventory_restored} =
        Repo.transaction(fn ->
          SQL.query!(c.owner_repo, drift(c, kind), [])
          assertion.()
          Repo.rollback(:inventory_restored)
        end)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp drift(c, :constraints) do
    name =
      scalar(
        c.owner_repo,
        "SELECT conname FROM pg_constraint WHERE conrelid=to_regclass($1) AND contype='c' AND pg_get_constraintdef(oid) LIKE '%attempt >= 1%'",
        [rel(c, "ash_onetime_effect_outcomes")]
      )

    "ALTER TABLE #{rel(c, "ash_onetime_effect_outcomes")} DROP CONSTRAINT #{q(name)}"
  end

  defp drift(c, :triggers),
    do:
      "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} DISABLE TRIGGER ash_onetime_idempotency_update_guard"

  defp drift(c, :policies),
    do:
      "ALTER POLICY ash_onetime_claim_visibility ON #{rel(c, "ash_onetime_effect_outcomes")} USING (false) WITH CHECK (false)"

  defp drift(c, :routines),
    do:
      "ALTER FUNCTION #{routine(c, "ash_onetime_claim_visible")}(bytea,text,uuid) SET lock_timeout='5s'"

  defp drift(c, :table_acls),
    do: "GRANT DELETE ON #{rel(c, "ash_onetime_effect_outcomes")} TO #{q(c.runtime)}"

  defp drift(c, :column_acls),
    do: "GRANT UPDATE(outcome) ON #{rel(c, "ash_onetime_effect_outcomes")} TO #{q(c.runtime)}"

  defp drift(c, :journal_acls),
    do: "GRANT SELECT ON #{rel(c, "ash_onetime_external_state_restore")} TO #{q(c.runtime)}"

  defp normalize(value, c) when is_binary(value) do
    value
    |> String.replace(Postgres.routine_schema(c.schema), "<routines>")
    |> String.replace(c.schema, "<schema>")
  end

  defp normalize(value, c) when is_list(value), do: Enum.map(value, &normalize(&1, c))
  defp normalize(value, _c), do: value
end
