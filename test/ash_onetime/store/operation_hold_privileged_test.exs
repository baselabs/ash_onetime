defmodule AshOnetime.Store.OperationHoldPrivilegedTest do
  use ExUnit.Case, async: false

  alias AshOnetime.{Store, Transaction}
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  @moduletag :operation_hold_superuser
  unless System.get_env("ASH_ONETIME_SUPERUSER_URL") do
    @moduletag skip:
                 "supply ASH_ONETIME_SUPERUSER_URL for an isolated PostgreSQL 18 superuser connection"
  end

  setup do
    url = System.fetch_env!("ASH_ONETIME_SUPERUSER_URL")
    super = start_repo(url)
    unique = System.unique_integer([:positive])
    owner = "hold_owner_#{unique}"
    runtime = "hold_runtime_#{unique}"
    schema = "hold_probe_#{unique}"
    password = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    module = Module.concat(__MODULE__, "Install#{unique}")
    previous = Repo.get_dynamic_repo()

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      query!(super, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|)
      for role <- [runtime, owner], do: query!(super, ~s|DROP ROLE IF EXISTS "#{role}"|)
      stop_repo(super)
      :code.purge(module)
      :code.delete(module)
    end)

    assert %{rows: [[true, 18]]} =
             query!(
               super,
               "SELECT rolsuper, current_setting('server_version_num')::integer / 10000 FROM pg_roles WHERE rolname = current_user"
             )

    for role <- [owner, runtime] do
      query!(
        super,
        ~s|CREATE ROLE "#{role}" LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '#{password}'|
      )
    end

    query!(super, ~s|CREATE SCHEMA "#{schema}" AUTHORIZATION "#{owner}"|)
    owner_repo = start_repo(role_url(url, owner, password))
    on_exit(fn -> stop_repo(owner_repo) end)
    Repo.put_dynamic_repo(owner_repo)

    source =
      Generator.render(Repo, [])
      |> String.replace(inspect(Repo) <> ".Migrations.InstallAshOnetime", inspect(module))

    Code.compile_string(source)
    assert :ok = Ecto.Migrator.up(Repo, 1, module, prefix: schema, log: false)

    Process.put({__MODULE__, :role_password}, password)
    {:ok, super: super, owner_repo: owner_repo, runtime: runtime, schema: schema}
  end

  test "the delete guard stops a direct DELETE by a superuser", ctx do
    seed!(ctx.schema, "scope")
    Repo.put_dynamic_repo(ctx.super)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:error,
                       %Postgrex.Error{postgres: %{code: :check_violation, message: message}}} =
                        SQL.query(ctx.super, "DELETE FROM #{claims(ctx.schema)}", [],
                          mode: :savepoint
                        )

               assert message =~ "held idempotency claim",
                      "the guard must stop even the superuser's DELETE"

               assert count(ctx.super, ctx.schema) == 1
               :ok
             end)
  end

  test "the guard does not stop owner TRUNCATE, superuser replica-mode DELETE, or owner DROP",
       ctx do
    seed!(ctx.schema, "scope")

    for operation <- [:truncate, :replica, :drop] do
      repo = if operation == :replica, do: ctx.super, else: ctx.owner_repo
      Repo.put_dynamic_repo(repo)

      assert {:error, :probe_finished} =
               Repo.transaction(fn ->
                 case operation do
                   :truncate ->
                     query!(repo, "TRUNCATE #{claims(ctx.schema)}")

                     assert count(repo, ctx.schema) == 0,
                            "TRUNCATE does not invoke the DELETE guard"

                   :replica ->
                     query!(repo, "SET LOCAL session_replication_role = replica")
                     assert %{num_rows: 1} = query!(repo, "DELETE FROM #{claims(ctx.schema)}")
                     assert count(repo, ctx.schema) == 0, "replica mode bypasses the DELETE guard"

                   :drop ->
                     query!(repo, "DROP TABLE #{claims(ctx.schema)} CASCADE")

                     assert %{rows: [[nil]]} =
                              query!(repo, "SELECT to_regclass($1)", [
                                ctx.schema <> ".ash_onetime_idempotency_claims"
                              ])
                 end

                 Repo.rollback(:probe_finished)
               end)

      assert count(ctx.super, ctx.schema) == 1, "the probe rollback must restore the held claim"
    end
  end

  test "a non-owner runtime role releases only its tenant under FORCE row security", ctx do
    for scope <- ["tenant-a", "tenant-b"], do: seed!(ctx.schema, scope)

    %{rows: [[scope_hash]]} =
      query!(
        ctx.super,
        "SELECT encode(scope_hash, 'hex') FROM #{claims(ctx.schema)} ORDER BY inserted_at LIMIT 1"
      )

    query!(ctx.super, "ALTER TABLE #{claims(ctx.schema)} ENABLE ROW LEVEL SECURITY")
    query!(ctx.super, "ALTER TABLE #{claims(ctx.schema)} FORCE ROW LEVEL SECURITY")

    query!(
      ctx.super,
      ~s|CREATE POLICY tenant_scope ON #{claims(ctx.schema)} TO "#{ctx.runtime}" USING (encode(scope_hash, 'hex') = current_setting('ash_onetime.test_scope', true))|
    )

    query!(ctx.super, ~s|GRANT USAGE ON SCHEMA "#{ctx.schema}" TO "#{ctx.runtime}"|)
    query!(ctx.super, ~s|GRANT SELECT, UPDATE ON #{claims(ctx.schema)} TO "#{ctx.runtime}"|)

    runtime_repo =
      start_repo(
        role_url(
          System.fetch_env!("ASH_ONETIME_SUPERUSER_URL"),
          ctx.runtime,
          Process.get({__MODULE__, :role_password})
        ),
        parameters: [{"ash_onetime.test_scope", scope_hash}]
      )

    try do
      Repo.put_dynamic_repo(runtime_repo)

      assert %{rows: [[false, false, false]]} =
               query!(
                 runtime_repo,
                 "SELECT r.rolsuper, r.rolbypassrls, c.relowner = r.oid FROM pg_roles r CROSS JOIN pg_class c WHERE r.rolname = current_user AND c.oid = $1::text::regclass",
                 [ctx.schema <> ".ash_onetime_idempotency_claims"]
               )

      assert {:ok, %{held_count: 1}} = Store.held_backlog(Postgres.for_repo(Repo, ctx.schema))

      assert {:ok, {:ok, 1}} =
               Repo.transaction(fn ->
                 Transaction.release(Repo,
                   prefix: ctx.schema,
                   partition: "global",
                   reference: "shared-reference"
                 )
               end)

      assert {:ok, {:ok, 0}} =
               Repo.transaction(fn ->
                 Transaction.release(Repo,
                   prefix: ctx.schema,
                   partition: "global",
                   reference: "shared-reference"
                 )
               end)

      assert %{rows: [[1, 1]]} =
               query!(
                 ctx.super,
                 "SELECT count(*) FILTER (WHERE hold_reference IS NULL), count(*) FILTER (WHERE hold_reference = 'shared-reference') FROM #{claims(ctx.schema)}"
               )
    after
      Repo.put_dynamic_repo(ctx.owner_repo)
      stop_repo(runtime_repo)
    end
  end

  defp seed!(schema, scope) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:execute, admission} =
                        Transaction.idempotency(Repo,
                          operation: {__MODULE__, :open},
                          partition: "global",
                          prefix: schema,
                          scope: scope,
                          key: "request",
                          fingerprint: :crypto.hash(:sha256, "body"),
                          retention_seconds: 3_600,
                          codec: "test"
                        )

               Transaction.complete(admission, "response", hold: "shared-reference")
             end)

    query!(
      Repo.get_dynamic_repo(),
      "UPDATE #{claims(schema)} SET admitted_at = statement_timestamp() - interval '2 days', inserted_at = statement_timestamp() - interval '2 days', retain_until = statement_timestamp() - interval '1 day'"
    )
  end

  defp start_repo(url, opts \\ []) do
    {:ok, pid} =
      Repo.start_link(
        [name: nil, url: url, pool: DBConnection.ConnectionPool, pool_size: 2] ++ opts
      )

    Process.unlink(pid)
    pid
  end

  defp role_url(url, role, password),
    do:
      URI.to_string(%{
        URI.parse(url)
        | userinfo: URI.encode_www_form(role) <> ":" <> URI.encode_www_form(password)
      })

  defp stop_repo(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000))
  defp query!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)
  defp claims(schema), do: ~s|"#{schema}".ash_onetime_idempotency_claims|

  defp count(repo, schema),
    do: query!(repo, "SELECT count(*) FROM #{claims(schema)}").rows |> hd() |> hd()
end
