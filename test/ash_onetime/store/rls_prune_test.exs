defmodule AshOnetime.Store.RLSPruneTest do
  @moduledoc """
  The payload-partition prune under FORCE row-level security, on real PostgreSQL.

  A superuser bypasses RLS, so every prune here runs over a connection whose
  role is asserted to be neither superuser nor BYPASSRLS. Tier 1 (the filtering
  defect and the fail-closed refusal) needs only that: the shared instance's
  own non-superuser role owns the tables. Tier 2 (the dedicated prune role and
  its function) also needs to create roles; it self-bootstraps when the main
  role is superuser (CI, an ephemeral area run) and is skipped with instructions
  otherwise — see .kimosabe/memory/test-substrate-and-ephemeral-area.md.
  """

  use ExUnit.Case, async: false

  alias AshOnetime.Store.Postgres
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

  # Every test builds and drops its own schema and roles, so the suite runs
  # with the pool in auto mode (the migrator spawns its own processes, which
  # cannot check out a sandbox-owned connection).
  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  @tenant_setting "ash_onetime.tenant"
  @prune_role "ash_onetime_prune"

  # The function tier creates roles, which needs a superuser or CREATEROLE
  # substrate: CI (its containerized postgres) and an ephemeral area run set
  # ASH_ONETIME_RLS_PRUNE_TESTS=1; the shared dev instance leaves the tier
  # skipped with instructions. A run that sets the variable on a substrate
  # that cannot deliver fails loudly in rls_substrate!/1.
  @rls_prune_tier if System.get_env("ASH_ONETIME_RLS_PRUNE_TESTS") == "1",
                    do: [],
                    else: [
                      skip:
                        "set ASH_ONETIME_RLS_PRUNE_TESTS=1 on a superuser or " <>
                          "CREATEROLE substrate (CI, or an ephemeral area run with DATABASE_URL " <>
                          "pointed at it for the command)"
                    ]

  # ------------------------------------------------------------------
  # Substrate
  # ------------------------------------------------------------------

  defp role_privileges(repo \\ Repo) do
    %{rows: [[superuser?, bypassrls?, createrole?]]} =
      SQL.query!(
        repo,
        "SELECT rolsuper, rolbypassrls, rolcreaterole FROM pg_roles WHERE rolname = current_user",
        []
      )

    %{superuser?: superuser?, bypassrls?: bypassrls?, createrole?: createrole?}
  end

  defp start_tenant_repo!(base_url, tenant) do
    {:ok, repo} =
      Repo.start_link(
        name: nil,
        url: base_url,
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        parameters: [{@tenant_setting, tenant}]
      )

    Process.unlink(repo)
    on_exit(fn -> stop_repo(repo) end)
    repo
  end

  defp stop_repo(repo) do
    if Process.alive?(repo) do
      try do
        GenServer.stop(repo, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp query!(repo, sql, params \\ []) do
    case SQL.query(repo, sql, params) do
      {:ok, result} ->
        result

      {:error, error} ->
        raise "query failed: #{Exception.message(error)} SQL=#{String.slice(sql || "", 0, 120)}"
    end
  end

  defp put_repo(repo) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    :ok
  end

  # ------------------------------------------------------------------
  # Tier 1 — the filtering defect and the fail-closed refusal
  # ------------------------------------------------------------------

  @tag rls_prune_fail_closed_mutation: true
  test "FORCE RLS must not let a tenant-filtered count drop another tenant's partition" do
    tier1 = tier1_substrate!()
    base_url = if(tier1.privileged, do: owner_url(), else: database_url())

    %{prefix: prefix} = install_rls_store!(tier1)
    partition = partition_name(~D[2026-09-01])
    on_exit(fn -> drop_quietly(prefix) end)

    # Tenant B's replay payload sits alone in a past-month partition. Cleanup
    # for tenant A must never see that as an empty partition.
    insert_payload!(prefix, partition, "tenant-b", ~D[2026-09-15])

    tenant_a = start_tenant_repo!(base_url, "tenant-a")

    # The tier-1 substrate's connection may hold CREATEROLE (the privileged
    # owner role); what it must never hold is superuser or BYPASSRLS.
    assert %{superuser?: false, bypassrls?: false} = role_privileges(tenant_a)

    put_repo(tenant_a)

    result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 1)

    Repo.put_dynamic_repo(Repo)

    assert partition_exists?(prefix, partition),
           "cleanup dropped a partition that still held tenant B's payload"

    assert %{reason: :row_security_blocked} = result

    tenant_b = start_tenant_repo!(base_url, "tenant-b")
    count = scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{partition}\"", [])
    assert count == 1

    stop_repo(tenant_a)
    stop_repo(tenant_b)
    tier1_takedown(tier1)
  end

  @tag rls_prune_fail_closed_mutation: true
  test "a partition with no rows at all still refuses: a filtered count is never trusted" do
    tier1 = tier1_substrate!()
    base_url = if(tier1.privileged, do: owner_url(), else: database_url())

    %{prefix: prefix} = install_rls_store!(tier1)
    partition = partition_name(~D[2026-09-01])
    on_exit(fn -> drop_quietly(prefix) end)

    tenant_a = start_tenant_repo!(base_url, "tenant-a")
    put_repo(tenant_a)

    result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 1)

    Repo.put_dynamic_repo(Repo)

    # The unfiltered partition holds no rows, but the closed refusal still
    # wins: a filtered count is never trusted, even when it happens to be
    # right. The dedicated-function tier below is the sanctioned prune.
    assert %{reason: :row_security_blocked} = result
    assert partition_exists?(prefix, partition)
    stop_repo(tenant_a)
    tier1_takedown(tier1)
  end

  # Tier 1 runs on the shared instance's own non-superuser role when it can,
  # and through a freshly created owner role when the main connection is a
  # superuser (CI, ephemeral area runs) — a superuser would bypass RLS and
  # make both tests pass falsely.
  defp tier1_substrate! do
    if role_privileges().superuser? do
      substrate = rls_substrate!()

      %{
        install_repo: substrate.owner_repo,
        owner_role: substrate.owner_role,
        privileged: true
      }
    else
      %{base_url: database_url(), install_repo: Repo, privileged: false}
    end
  end

  defp owner_url, do: Process.get({__MODULE__, :owner_url})

  defp tier1_takedown(%{privileged: false}), do: :ok

  defp tier1_takedown(%{install_repo: install_repo}) do
    stop_repo(install_repo)
  end

  # ------------------------------------------------------------------
  # Tier 2 — the dedicated prune role and its function
  # ------------------------------------------------------------------

  describe "with the --rls-prune function" do
    @tag @rls_prune_tier
    test "an empty partition drops and another tenant's partition survives" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store_with_function!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])
      occupied_partition = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied_partition, "tenant-b", ~D[2026-08-15])

      put_repo(substrate.owner_repo)

      assert {:ok, %{payload_partitions: 1}} =
               Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      refute partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, occupied_partition)

      tenant_b = start_tenant_repo!(owner_url(), "tenant-b")

      assert scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{occupied_partition}\"", []) ==
               1

      stop_repo(tenant_b)
    end

    @tag @rls_prune_tier
    test "a child partition created by roll_partitions after the policies inherits them" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store_with_function!(install_context(substrate))

      put_repo(substrate.owner_repo)

      {:ok, _} = Postgres.roll_partitions(Postgres.for_repo(Repo, prefix), 15)

      Repo.put_dynamic_repo(Repo)

      # roll_partitions only creates the current month forward, so prove the
      # inheritance directly: the fresh child carries the parent's ENABLE and
      # FORCE row-security settings, every parent policy (the prune policy
      # included), and the prune role's SELECT grant.
      # Beyond the install migration's 13-month window, so the child is
      # genuinely created by this roll.
      child = partition_name(shift_months(Date.beginning_of_month(Date.utc_today()), 14))

      assert partition_exists?(prefix, child)

      flags =
        scalar_rows!(
          Repo,
          "SELECT relrowsecurity, relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2",
          [prefix, child]
        )

      assert flags == [[true, true]]

      inherited =
        scalar_rows!(
          Repo,
          "SELECT policyname FROM pg_policies WHERE schemaname = $1 AND tablename = $2 ORDER BY 1",
          [prefix, child]
        )

      assert ["ash_onetime_prune_select", "tenant_isolation"] = Enum.map(inherited, &hd/1)

      # And the function counts a tenant-B row in that child as non-empty,
      # reading through the inherited prune policy as the application role.
      insert_payload!(prefix, child, "tenant-b", shift_months(Date.utc_today(), 14))
      tenant_b = start_tenant_repo!(owner_url(), "tenant-b")
      assert scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{child}\"", []) == 1
      stop_repo(tenant_b)

      app = start_tenant_repo!(Process.get({__MODULE__, :app_url}), "tenant-a")

      empty? =
        scalar!(
          app,
          "SELECT #{prefix}.ash_onetime_partition_empty($1, $2, $3)",
          ["\"#{prefix}\".\"#{child}\"", ~D[2026-01-01], ~D[2027-01-01]]
        )

      assert empty? == false
      stop_repo(app)
    end

    @tag @rls_prune_tier
    test "the application role cannot become or read through the prune role" do
      substrate = rls_substrate!()
      install_rls_store_with_function!(install_context(substrate))

      # pg_has_role knows MEMBER/USAGE/SET; the admin option shows up as a
      # pg_auth_members row, so assert no membership row exists at all.
      set =
        scalar!(substrate.bootstrap_repo, "SELECT pg_has_role($1, $2, 'SET')", [
          substrate.app_role,
          @prune_role
        ])

      usage =
        scalar!(substrate.bootstrap_repo, "SELECT pg_has_role($1, $2, 'USAGE')", [
          substrate.app_role,
          @prune_role
        ])

      member_rows =
        scalar!(
          substrate.bootstrap_repo,
          """
          SELECT count(*) FROM pg_auth_members m
          JOIN pg_roles pr ON pr.oid = m.roleid
          JOIN pg_roles ap ON ap.oid = m.member
          WHERE pr.rolname = $1 AND ap.rolname = $2
          """,
          [@prune_role, substrate.app_role]
        )

      refute set
      refute usage
      assert member_rows == 0

      assert_raise Postgrex.Error, ~r/permission denied to set role/i, fn ->
        SQL.query!(substrate.app_repo, "SET ROLE #{@prune_role}", [])
      end
    end

    @tag @rls_prune_tier
    test "a restrictive tenant policy fails the prune closed instead of miscounting" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store_with_function!(install_context(substrate))
      occupied = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied, "tenant-b", ~D[2026-08-15])

      # A consumer's tenant isolation hardened as RESTRICTIVE on the claims
      # table, the payload parent, and the partition. The prune role's
      # permissive USING (true) policy is only ORed with permissive policies;
      # the restrictive one is ANDed in, so the function's counts would see
      # only the current tenant. The function must refuse to count instead.
      for table <- ["ash_onetime_idempotency_claims", "ash_onetime_response_payloads", occupied] do
        query!(
          substrate.owner_repo,
          """
          CREATE POLICY tenant_hard ON "#{prefix}"."#{table}"
          AS RESTRICTIVE
          USING (logical_partition = current_setting('#{@tenant_setting}', true))
          """,
          []
        )
      end

      put_repo(substrate.owner_repo)

      result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      assert %{reason: :row_security_blocked} = result
      assert partition_exists?(prefix, occupied)

      tenant_b = start_tenant_repo!(owner_url(), "tenant-b")
      assert scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{occupied}\"", []) == 1
      stop_repo(tenant_b)
    end

    @tag @rls_prune_tier
    test "a partition_name that is not a payload child is refused" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store_with_function!(install_context(substrate))

      app = start_tenant_repo!(Process.get({__MODULE__, :app_url}), "tenant-a")

      assert_raise Postgrex.Error,
                   ~r/row-level security|not a payload partition/,
                   fn ->
                     SQL.query!(
                       app,
                       "SELECT #{prefix}.ash_onetime_partition_empty($1, $2, $3)",
                       [
                         "\"#{prefix}\".\"ash_onetime_idempotency_claims\"",
                         ~D[2026-08-01],
                         ~D[2026-09-01]
                       ]
                     )
                   end

      stop_repo(app)
    end

    @tag @rls_prune_tier
    test "EXECUTE is revoked from PUBLIC and granted only to the application role" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store_with_function!(install_context(substrate))

      # has_function_privilege's OID form: the text form parses double quotes
      # as part of the name.
      privileges =
        "SELECT has_function_privilege($1, (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = 'ash_onetime_partition_empty' AND n.nspname = $2), 'EXECUTE')"

      assert scalar!(Repo, privileges, [substrate.app_role, prefix]) == true

      # Any third role: PUBLIC must not hold EXECUTE.
      third = "ash_onetime_rls_third_#{System.unique_integer([:positive])}"
      SQL.query!(Repo, "CREATE ROLE #{third} LOGIN", [])

      on_exit(fn -> drop_role_quietly(Repo, third) end)

      assert scalar!(Repo, privileges, [third, prefix]) == false
    end

    @tag @rls_prune_tier
    test "the migration refuses to run as the application role" do
      substrate = rls_substrate!()
      installed = install_rls_store_with_function!(install_context(substrate), run_rls: false)
      %{prefix: prefix, facts: facts} = installed

      Repo.put_dynamic_repo(substrate.app_repo)

      assert_refusal("must not be the application role", fn ->
        Ecto.Migrator.up(Repo, facts.version, facts.module, prefix: prefix, log: false)
      end)

      Repo.put_dynamic_repo(Repo)
      assert function_exists?(substrate.bootstrap_repo, prefix) == false
    end

    @tag @rls_prune_tier
    test "the migration refuses when the application role holds SET on the prune role" do
      substrate = rls_substrate!()
      installed = install_rls_store_with_function!(install_context(substrate), run_rls: false)
      %{prefix: prefix, facts: facts} = installed

      # The role must exist for the pre-grant; the owner creates it, so it
      # holds ADMIN and can grant the application role SET.
      SQL.query!(substrate.owner_repo, "CREATE ROLE #{@prune_role} NOLOGIN", [])

      SQL.query!(
        substrate.owner_repo,
        "GRANT #{@prune_role} TO #{substrate.app_role} WITH INHERIT FALSE, SET TRUE",
        []
      )

      Repo.put_dynamic_repo(substrate.owner_repo)

      assert_refusal("SET, USAGE, or ADMIN", fn ->
        Ecto.Migrator.up(Repo, facts.version, facts.module, prefix: prefix, log: false)
      end)

      Repo.put_dynamic_repo(Repo)
      assert function_exists?(substrate.bootstrap_repo, prefix) == false
    end
  end

  # ------------------------------------------------------------------
  # Substrate helpers
  # ------------------------------------------------------------------

  defp database_url do
    Application.fetch_env!(:ash_onetime, Repo)[:url]
  end

  # The migrator surfaces its failures as raises inside its task or as
  # {:error, error} returns depending on the path; accept either.
  defp assert_refusal(expected, fun) do
    outcome =
      try do
        {:returned, fun.()}
      rescue
        e -> {:raised, e}
      end

    message =
      case outcome do
        {:raised, %Postgrex.Error{postgres: %{message: message}}} -> message
        {:returned, {:error, %Postgrex.Error{postgres: %{message: message}}}} -> message
      end

    assert message =~ expected
  end

  defp database_name do
    database_url() |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")
  end

  defp rls_substrate! do
    privileges = role_privileges()

    unless privileges.superuser? or privileges.createrole? do
      flunk(
        "ASH_ONETIME_RLS_PRUNE_TESTS=1 needs a superuser or CREATEROLE connection " <>
          "(CI, or an ephemeral area run with DATABASE_URL pointed at it for the command)"
      )
    end

    case bootstrap_rls_substrate() do
      {:ok, substrate} -> substrate
    end
  end

  defp bootstrap_rls_substrate do
    unique = System.unique_integer([:positive])
    owner_role = "ash_onetime_rls_owner_#{unique}"
    app_role = "ash_onetime_rls_app_#{unique}"
    owner_password = random_password()
    app_password = random_password()
    url = database_url()

    # Leftovers from an aborted run would break the not-exists creation (and
    # a role owning functions cannot be dropped); the privileged connection
    # owns this substrate and clears both.
    drop_leftover_substrate!()

    query!(
      Repo,
      "CREATE ROLE #{owner_role} LOGIN CREATEROLE PASSWORD #{quote_literal(owner_password)}",
      []
    )

    query!(Repo, "CREATE ROLE #{app_role} LOGIN PASSWORD #{quote_literal(app_password)}", [])

    owner_url =
      url
      |> URI.parse()
      |> Map.put(:userinfo, "#{owner_role}:#{URI.encode_www_form(owner_password)}")
      |> URI.to_string()

    app_url =
      url
      |> URI.parse()
      |> Map.put(:userinfo, "#{app_role}:#{URI.encode_www_form(app_password)}")
      |> URI.to_string()

    {:ok, owner_repo} =
      Repo.start_link(name: nil, url: owner_url, pool: DBConnection.ConnectionPool, pool_size: 2)

    {:ok, app_repo} =
      Repo.start_link(name: nil, url: app_url, pool: DBConnection.ConnectionPool, pool_size: 2)

    Process.unlink(owner_repo)
    Process.unlink(app_repo)

    on_exit(fn ->
      stop_repo(owner_repo)
      stop_repo(app_repo)
      # Self-sufficient teardown: schemas this substrate created die first
      # (a role owning objects cannot drop), then the roles. The database
      # CREATE grant must go before the owner role itself can drop.
      Repo.put_dynamic_repo(Repo)
      drop_leftover_substrate!()
      _ = SQL.query(Repo, ~s{REVOKE CREATE ON DATABASE #{database_name()} FROM #{owner_role}}, [])
      drop_role_quietly(Repo, owner_role)
      drop_role_quietly(Repo, app_role)
    end)

    # Credentials stay out of returned maps (ExUnit prints them on failure);
    # the URLs live in the process dictionary.
    Process.put({__MODULE__, :owner_url}, owner_url)
    Process.put({__MODULE__, :app_url}, app_url)

    {:ok,
     %{
       bootstrap_repo: Repo,
       owner_repo: owner_repo,
       app_repo: app_repo,
       owner_role: owner_role,
       app_role: app_role
     }}
  end

  defp random_password do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end

  defp quote_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp drop_leftover_substrate! do
    result =
      SQL.query!(
        Repo,
        "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'ash_onetime_rls_%'",
        []
      )

    Enum.each(result.rows, fn [namespace] ->
      _ = SQL.query(Repo, ~s{DROP SCHEMA IF EXISTS "#{namespace}" CASCADE}, [])
    end)

    # Leftover owner/app roles from an aborted run on a long-lived instance
    # (the ephemeral pod survives across command reruns; the counter restarts
    # with every VM, so names recur). The database CREATE grant must go
    # before the role can drop.
    leftovers =
      SQL.query!(
        Repo,
        "SELECT rolname FROM pg_roles WHERE rolname LIKE 'ash_onetime_rls_%'",
        []
      )

    Enum.each(leftovers.rows, fn [role] ->
      _ =
        SQL.query(
          Repo,
          ~s{REVOKE CREATE ON DATABASE #{database_name()} FROM #{role}},
          []
        )

      drop_role_quietly(Repo, role)
    end)

    drop_role_quietly(Repo, @prune_role)
  end

  defp drop_role_quietly(repo, role) do
    _ =
      SQL.query(
        repo,
        "DROP ROLE IF EXISTS #{role}",
        []
      )

    :ok
  end

  # ------------------------------------------------------------------
  # Store + RLS installation
  # ------------------------------------------------------------------

  defp install_rls_store!(tier1) do
    install_rls_store_with_function!(tier1)
  end

  defp install_rls_store_with_function!(context, options \\ []) do
    unique = Ecto.UUID.generate() |> String.replace("-", "")
    prefix = "ash_onetime_rls_#{unique}"
    temporary = Path.join(System.tmp_dir!(), "ash_onetime_rls_#{unique}")
    migrations = Path.join(temporary, "migrations")

    Mix.Task.reenable("ash_onetime.gen.migrations")

    arguments =
      ["--repo", inspect(Repo), "--migrations-path", migrations, "--timestamp", "20261108000000"] ++
        if(app_role = context[:app_role],
          do: ["--rls-prune", "--app-role", app_role],
          else: []
        )

    GenerateMigrations.run(arguments)

    [install_path] = Path.wildcard(Path.join(migrations, "*_install_ash_onetime.exs"))
    [{install_module, _}] = Code.compile_file(install_path)
    install_version = 2_026_110_800_000

    rls_facts =
      if context[:app_role] do
        [rls_path] = Path.wildcard(Path.join(migrations, "*_ash_onetime_rls_prune.exs"))
        [{rls_module, _}] = Code.compile_file(rls_path)
        %{module: rls_module, version: 2_026_110_800_001}
      end

    install_repo = context[:install_repo] || Repo

    try do
      provision_schema!(context, install_repo, prefix)
      migrate!(install_repo, prefix, install_version, install_module, rls_facts, options)
      harden_row_security!(context, install_repo, prefix)

      Map.merge(context, %{prefix: prefix, temporary: temporary, facts: rls_facts})
    after
      Repo.put_dynamic_repo(Repo)
    end
  end

  # The migrating role owns its schema (as in a real consumer install), so it
  # can grant the prune role the CREATE the ownership transfer requires; it
  # needs CREATE on the database to create the schema.
  # The shared instance's own role creates its schema directly.
  defp provision_schema!(_context, Repo, prefix) do
    query!(Repo, ~s{CREATE SCHEMA "#{prefix}"}, [])
  end

  defp provision_schema!(context, install_repo, prefix) do
    owner_role = context.owner_role

    query!(Repo, ~s{GRANT CREATE ON DATABASE #{database_name()} TO #{owner_role}}, [])
    Repo.put_dynamic_repo(install_repo)
    query!(install_repo, ~s{CREATE SCHEMA "#{prefix}"}, [])
    Repo.put_dynamic_repo(Repo)
    query!(Repo, ~s{GRANT USAGE ON SCHEMA "#{prefix}" TO #{owner_role}}, [])

    # CREATE too: the refusal tests still need the migrator to reach the
    # migration's own guards (Ecto writes schema_migrations first).
    if context[:app_role] do
      query!(Repo, ~s{GRANT USAGE, CREATE ON SCHEMA "#{prefix}" TO #{context.app_role}}, [])
    end

    Repo.put_dynamic_repo(install_repo)
  end

  defp migrate!(_install_repo, prefix, install_version, install_module, rls_facts, options) do
    :ok = Ecto.Migrator.up(Repo, install_version, install_module, prefix: prefix, log: false)

    if rls_facts && options[:run_rls] != false do
      :ok =
        Ecto.Migrator.up(Repo, rls_facts.version, rls_facts.module, prefix: prefix, log: false)
    end
  end

  # FORCE row-level security with a per-tenant policy, past-month partitions,
  # and (when present) the application role's ordinary DML over the store.
  defp harden_row_security!(context, install_repo, prefix) do
    Repo.put_dynamic_repo(Repo)

    if context[:app_role] do
      for kind <- ["TABLES", "SEQUENCES", "FUNCTIONS"] do
        query!(
          Repo,
          ~s{GRANT ALL ON ALL #{kind} IN SCHEMA "#{prefix}" TO #{context.app_role}},
          []
        )
      end
    end

    Repo.put_dynamic_repo(install_repo)
    apply_rls!(install_repo, prefix)
    create_partition!(install_repo, prefix, ~D[2026-09-01], ~D[2026-10-01])
    create_partition!(install_repo, prefix, ~D[2026-08-01], ~D[2026-09-01])
  end

  defp install_context(substrate) do
    %{
      install_repo: substrate.owner_repo,
      owner_role: substrate.owner_role,
      app_role: substrate.app_role
    }
  end

  defp apply_rls!(repo, prefix) do
    for table <- ["ash_onetime_idempotency_claims", "ash_onetime_response_payloads"] do
      query!(repo, ~s{ALTER TABLE "#{prefix}"."#{table}" ENABLE ROW LEVEL SECURITY}, [])
      query!(repo, ~s{ALTER TABLE "#{prefix}"."#{table}" FORCE ROW LEVEL SECURITY}, [])

      query!(
        repo,
        """
        CREATE POLICY tenant_isolation ON "#{prefix}"."#{table}"
        USING (logical_partition = current_setting('#{@tenant_setting}', true))
        """,
        []
      )
    end

    :ok
  end

  defp create_partition!(repo, prefix, from, until) do
    name = partition_name(from)

    query!(
      repo,
      """
      CREATE TABLE "#{prefix}"."#{name}" PARTITION OF "#{prefix}"."ash_onetime_response_payloads"
      FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(until)}')
      """,
      []
    )

    copy_parent_rls!(repo, prefix, name)
    name
  end

  defp copy_parent_rls!(repo, prefix, child) do
    query!(
      repo,
      """
      DO $copy$
      DECLARE
        child_oid regclass := '"#{prefix}"."#{child}"'::regclass;
        r record;
        roles text;
        cmd_part text;
        using_part text;
        check_part text;
        ddl text;
      BEGIN
        PERFORM format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', child_oid);
        PERFORM format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', child_oid);

        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ash_onetime_prune') THEN
          ddl := 'GRANT SELECT ON ' || child_oid || ' TO ash_onetime_prune';
          EXECUTE ddl;
        END IF;

        FOR r IN
          SELECT * FROM pg_policies
          WHERE schemaname = '#{prefix}' AND tablename = 'ash_onetime_response_payloads'
        LOOP
          IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = '#{prefix}' AND tablename = '#{child}' AND policyname = r.policyname
          ) THEN
            roles := coalesce(
              (SELECT string_agg(quote_ident(member), ', ') FROM unnest(r.roles) AS member), 'PUBLIC'
            );

            cmd_part := CASE r.cmd WHEN 'ALL' THEN '' ELSE 'FOR ' || r.cmd || ' ' END;
            using_part := CASE WHEN r.qual IS NULL THEN '' ELSE 'USING (' || r.qual || ') ' END;
            check_part := CASE WHEN r.with_check IS NULL THEN '' ELSE 'WITH CHECK (' || r.with_check || ')' END;

            ddl := 'CREATE POLICY ' || quote_ident(r.policyname) || ' ON ' || child_oid ||
              ' AS ' || r.permissive || ' ' || cmd_part || 'TO ' || roles || ' ' || using_part || check_part;
            EXECUTE ddl;
          END IF;
        END LOOP;
      END
      $copy$;
      """,
      []
    )
  end

  defp shift_months(date, offset) do
    index = date.year * 12 + date.month - 1 + offset
    Date.new!(div(index, 12), rem(index, 12) + 1, 1)
  end

  defp partition_name(month_start) do
    "ash_onetime_response_payloads_#{month_start.year}_#{String.pad_leading(Integer.to_string(month_start.month), 2, "0")}"
  end

  defp insert_payload!(prefix, partition, logical_partition, date) do
    tenant_repo = start_tenant_repo!(database_url(), logical_partition)

    query!(
      tenant_repo,
      """
      INSERT INTO "#{prefix}"."#{partition}"
        (logical_partition, partition_date, claim_id, encoded_response)
      VALUES ($1, $2, $3::uuid, $4)
      """,
      [logical_partition, date, Ecto.UUID.dump!(Ecto.UUID.generate()), <<0, 1, 2, 3>>]
    )

    stop_repo(tenant_repo)
    :ok
  end

  defp partition_exists?(prefix, partition) do
    result =
      SQL.query!(
        Repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_inherits
          JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
          JOIN pg_namespace ns ON ns.oid = parent.relnamespace
          JOIN pg_class child ON child.oid = pg_inherits.inhrelid
          WHERE ns.nspname = $1 AND parent.relname = 'ash_onetime_response_payloads'
            AND child.relname = $2
        )
        """,
        [prefix, partition]
      )

    result.rows == [[true]]
  end

  defp function_exists?(repo, prefix) do
    result =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE p.proname = 'ash_onetime_partition_empty' AND n.nspname = $1
        )
        """,
        [prefix]
      )

    result.rows == [[true]]
  end

  defp scalar!(repo, sql, params) do
    result = SQL.query!(repo, sql, params)
    [[value]] = result.rows
    value
  end

  defp scalar_rows!(repo, sql, params) do
    result = SQL.query!(repo, sql, params)
    result.rows
  end

  defp drop_quietly(prefix) do
    Repo.put_dynamic_repo(Repo)
    _ = SQL.query(Repo, ~s{DROP SCHEMA IF EXISTS "#{prefix}" CASCADE}, [])
    :ok
  end
end
