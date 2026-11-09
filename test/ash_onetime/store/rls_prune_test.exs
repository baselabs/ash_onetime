defmodule AshOnetime.Store.RLSPruneTest do
  @moduledoc """
  The payload-partition prune under FORCE row-level security, on real PostgreSQL.

  The prune decides DROP as the table owner inside a per-partition savepoint: an
  exclusive lock, an OID re-check (plain heap child of this schema's payload
  parent, owned by the driver), an uncommitted NO FORCE, and a count with
  row_security disabled. An owner of an un-FORCEd relation is exempt before the
  row_security check, so the count is unfiltered or errors — whatever policies
  exist. No role, function, or superuser is involved.

  A superuser bypasses RLS, so the owner-driven cells run on a non-superuser
  CREATEROLE substrate (tier 2 below) that self-bootstraps when the main
  connection is superuser (CI's containerized postgres, or an ephemeral area
  run with ASH_ONETIME_RLS_PRUNE_TESTS=1) and is skipped with instructions
  otherwise. Tier 1 (the fail-closed-keeps-cleanup and isolation-refusal
  cells) needs only the shared instance's own non-superuser role.
  """

  use ExUnit.Case, async: false

  alias AshOnetime.Store.Postgres
  alias AshOnetime.Store.Result
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

  # The matrix tier creates roles, which needs a superuser or CREATEROLE
  # substrate: CI (its containerized postgres sets ASH_ONETIME_RLS_PRUNE_TESTS=1)
  # and an ephemeral area run with the variable exported; the shared dev
  # instance leaves the tier skipped with instructions. A run that sets the
  # variable on a substrate that cannot deliver fails loudly in rls_substrate!/1.
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

  defp start_tenant_repo(base_url, tenant) do
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

  defp base_url(%{privileged: true}), do: owner_url()
  defp base_url(%{privileged: false}), do: database_url()

  # A session whose every BEGIN is REPEATABLE READ (the startup-packet
  # default), so cleanup's own transaction sees the wrong isolation.
  defp start_rr_repo(base_url) do
    {:ok, repo} =
      Repo.start_link(
        name: nil,
        url: base_url,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        parameters: [{"default_transaction_isolation", "repeatable read"}]
      )

    Process.unlink(repo)
    on_exit(fn -> stop_repo(repo) end)
    repo
  end

  # ------------------------------------------------------------------
  # Tier 1 — shared-instance cells
  # ------------------------------------------------------------------

  @tag rls_partition_kept_mutation: true
  @tag rls_prune_unforce_mutation: true
  @tag rls_prune_count_mutation: true
  test "tenant-session cleanup under FORCE RLS drops the empty partition, keeps the occupied one, and still deletes claims" do
    tier1 = tier1_substrate!()
    base_url = if(tier1.privileged, do: owner_url(), else: database_url())

    %{prefix: prefix} = install_rls_store!(tier1)
    partition = partition_name(~D[2026-09-01])
    on_exit(fn -> drop_quietly(prefix) end)

    # Tenant B's replay payload sits alone in a past-month partition; tenant
    # A's claim is past retention and eligible for cleanup.
    insert_payload!(prefix, partition, "tenant-b", ~D[2026-09-15])
    insert_completed_claim!(prefix, "tenant-a", ~D[2026-09-10])

    tenant_a = start_tenant_repo(base_url, "tenant-a")

    # The tier-1 substrate's connection may hold CREATEROLE (the privileged
    # owner role); what it must never hold is superuser or BYPASSRLS.
    assert %{superuser?: false, bypassrls?: false} = role_privileges(tenant_a)

    put_repo(tenant_a)

    # On the shared instance the tenant session IS the table owner, so this is
    # the owner-driven prune under a tenant context: the empty August sibling
    # drops, tenant B's occupied partition is kept with FORCE restored, and
    # the eligible claim is deleted in the same run (the F2 shape).
    result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

    Repo.put_dynamic_repo(Repo)

    assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} = result
    assert partition_exists?(prefix, partition)
    refute partition_exists?(prefix, partition_name(~D[2026-08-01]))
    assert force_flagged?(prefix, partition)

    assert scalar!(
             tenant_a,
             "SELECT count(*) FROM #{prefix}.\"ash_onetime_idempotency_claims\"",
             []
           ) ==
             0

    tenant_b = start_tenant_repo(base_url, "tenant-b")
    assert scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{partition}\"", []) == 1

    stop_repo(tenant_a)
    stop_repo(tenant_b)
    tier1_takedown(tier1)
  end

  @tag rls_isolation_precondition_mutation: true
  test "cleanup refuses when its transaction is not READ COMMITTED" do
    tier1 = tier1_substrate!()

    %{prefix: prefix} = install_rls_store!(tier1)
    partition = partition_name(~D[2026-09-01])
    insert_payload!(prefix, partition, "tenant-b", ~D[2026-09-15])
    on_exit(fn -> drop_quietly(prefix) end)

    # A stale REPEATABLE READ snapshot would read a partition empty even after
    # a row committed while the prune's lock waited (the F1 race the design
    # probe demonstrated live), so cleanup must refuse like every claim path.
    # The session-level default puts cleanup's own BEGIN at REPEATABLE READ.
    rr_repo = start_rr_repo(base_url(tier1))
    put_repo(rr_repo)

    result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 1)

    Repo.put_dynamic_repo(Repo)

    assert %Result{reason: :unsupported_isolation} = result
    assert partition_exists?(prefix, partition)
    stop_repo(rr_repo)
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
  defp app_url, do: Process.get({__MODULE__, :app_url})

  defp tier1_takedown(%{privileged: false}), do: :ok

  defp tier1_takedown(%{install_repo: install_repo}) do
    stop_repo(install_repo)
  end

  @tag rls_child_policy_copy_mutation: true
  test "a rolled child carries the parent's policies, so a direct tenant read stays scoped" do
    tier1 = tier1_substrate!()
    base_url = base_url(tier1)

    %{prefix: prefix} = install_rls_store!(tier1)
    on_exit(fn -> drop_quietly(prefix) end)

    # roll_partitions (the library path) creates a child beyond the install
    # window; the copy under test is Postgres.copy_parent_row_security/3.
    put_repo(tier1.install_repo)
    {:ok, _} = Postgres.roll_partitions(Postgres.for_repo(Repo, prefix), 15)
    Repo.put_dynamic_repo(Repo)

    child = partition_name(shift_months(Date.beginning_of_month(Date.utc_today()), 14))
    assert partition_exists?(prefix, child)

    child_date = shift_months(Date.utc_today(), 14)

    for tenant <- ["tenant-a", "tenant-b"] do
      session = start_tenant_repo(base_url, tenant)

      query!(
        session,
        "INSERT INTO \"#{prefix}\".\"ash_onetime_response_payloads\" VALUES ($1, $2, $3::uuid, $4)",
        [tenant, child_date, Ecto.UUID.dump!(Ecto.UUID.generate()), <<0, 1>>]
      )

      stop_repo(session)
    end

    # A direct, by-name read of the child: each tenant session sees exactly
    # its own rows. Without the copied policies the child would answer every
    # session with a default deny (or, un-RLS-ed, with every tenant's rows).
    for tenant <- ["tenant-a", "tenant-b"] do
      session = start_tenant_repo(base_url, tenant)
      assert scalar!(session, "SELECT count(*) FROM \"#{prefix}\".\"#{child}\"", []) == 1
      stop_repo(session)
    end

    tier1_takedown(tier1)
  end

  # ------------------------------------------------------------------
  # Tier 2 — the owner-savepoint matrix
  # ------------------------------------------------------------------

  describe "owner-driven prune" do
    @tag @rls_prune_tier
    test "an empty partition drops and an occupied one survives, under benign FORCE RLS" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])
      occupied_partition = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied_partition, "tenant-b", ~D[2026-08-15])

      put_repo(substrate.owner_repo)

      assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} =
               Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      refute partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, occupied_partition)
      assert force_flagged?(prefix, occupied_partition)

      tenant_b = start_tenant_repo(owner_url(), "tenant-b")

      assert scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{occupied_partition}\"", []) ==
               1

      stop_repo(tenant_b)
    end

    @tag @rls_prune_tier
    test "restrictive tenant policies keep the occupied partition and drop the empty sibling" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])
      occupied_partition = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied_partition, "tenant-b", ~D[2026-08-15])

      # The adversarial shape from the i-1 rounds: a RESTRICTIVE tenant policy
      # ANDed into any count. Under the owner-savepoint prune it is simply
      # irrelevant — the owner of an un-FORCEd relation is exempt before any
      # policy is consulted.
      for table <-
            [
              "ash_onetime_idempotency_claims",
              "ash_onetime_response_payloads",
              occupied_partition
            ] do
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

      assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} =
               Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      refute partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, occupied_partition)
      # The rollback-to-savepoint restored FORCE on the kept partition.
      assert force_flagged?(prefix, occupied_partition)
    end

    @tag @rls_prune_tier
    test "a child with no permissive policy for anyone still decides by row count" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])
      occupied_partition = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied_partition, "tenant-b", ~D[2026-08-15])

      # The default-deny shape that made the old catalog guard read "empty":
      # the occupied child carries RLS but no policy at all.
      query!(
        substrate.owner_repo,
        "DROP POLICY tenant_isolation ON \"#{prefix}\".\"#{occupied_partition}\"",
        []
      )

      put_repo(substrate.owner_repo)

      assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} =
               Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      refute partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, occupied_partition)
      assert force_flagged?(prefix, occupied_partition)
    end

    @tag @rls_prune_tier
    test "a sub-partitioned child is refused; its plain sibling drops" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])
      nested = partition_name(~D[2026-08-01])

      # Replace the plain August child with a sub-partitioned one holding
      # tenant B's row in a leaf. relkind 'p' must refuse (pg_relation_size
      # style emptiness shortcuts would read it as empty; FDW children would
      # count through a foreign server).
      query!(
        substrate.owner_repo,
        "DROP TABLE \"#{prefix}\".\"#{nested}\"",
        []
      )

      query!(
        substrate.owner_repo,
        """
        CREATE TABLE "#{prefix}"."#{nested}"
        PARTITION OF "#{prefix}"."ash_onetime_response_payloads"
        FOR VALUES FROM ('2026-08-01') TO ('2026-09-01') PARTITION BY LIST (logical_partition)
        """,
        []
      )

      query!(
        substrate.owner_repo,
        """
        CREATE TABLE "#{prefix}"."#{nested}_b" PARTITION OF "#{prefix}"."#{nested}"
        FOR VALUES IN ('tenant-b')
        """,
        []
      )

      insert_payload!(prefix, "#{nested}_b", "tenant-b", ~D[2026-08-15])

      put_repo(substrate.owner_repo)

      assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} =
               Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      refute partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, nested)

      tenant_b = start_tenant_repo(owner_url(), "tenant-b")

      assert scalar!(tenant_b, "SELECT count(*) FROM #{prefix}.\"#{nested}_b\"", []) == 1

      stop_repo(tenant_b)
    end

    @tag @rls_prune_tier
    test "a non-owner driver keeps every partition and still deletes claims" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])
      occupied_partition = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied_partition, "tenant-b", ~D[2026-08-15])
      insert_completed_claim!(prefix, "tenant-a", ~D[2026-08-10])

      app = start_tenant_repo(app_url(), "tenant-a")
      put_repo(app)

      result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      # Not the owner: both partitions are kept with a reason and — the F2
      # fix — the run succeeds and the eligible claim is gone.
      assert {:ok, %{payload_partitions: 0, payload_partitions_kept: 2}} = result
      assert partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, occupied_partition)

      assert scalar!(app, "SELECT count(*) FROM #{prefix}.\"ash_onetime_idempotency_claims\"", []) ==
               0

      stop_repo(app)
    end

    @tag @rls_prune_tier
    @tag rls_error_to_kept_mutation: true
    test "an event trigger blocking ALTER TABLE keeps partitions and fails nothing" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      empty_partition = partition_name(~D[2026-09-01])

      put_repo(substrate.owner_repo)

      query!(
        Repo,
        """
        CREATE FUNCTION "#{prefix}".block_ddl() RETURNS event_trigger
        LANGUAGE plpgsql AS $b$ BEGIN RAISE EXCEPTION 'DDL blocked'; END $b$
        """,
        []
      )

      query!(
        Repo,
        """
        CREATE EVENT TRIGGER ash_onetime_test_no_alter ON ddl_command_start
        WHEN TAG IN ('ALTER TABLE') EXECUTE FUNCTION "#{prefix}".block_ddl()
        """,
        []
      )

      on_exit(fn ->
        _ = SQL.query(Repo, "DROP EVENT TRIGGER IF EXISTS ash_onetime_test_no_alter", [])
        :ok
      end)

      assert {:ok, %{payload_partitions: 0, payload_partitions_kept: 2}} =
               Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)

      # Both past partitions were installed empty; both are kept under the
      # DDL block, and FORCE was restored on each by the savepoint rollback.
      assert partition_exists?(prefix, empty_partition)
      assert partition_exists?(prefix, partition_name(~D[2026-08-01]))
      assert force_flagged?(prefix, empty_partition)
    end

    @tag @rls_prune_tier
    test "an insert committed while the prune waits is counted, not dropped" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      occupied_partition = partition_name(~D[2026-08-01])
      insert_payload!(prefix, occupied_partition, "tenant-b", ~D[2026-08-15])

      # The racer targets the EMPTY September sibling — the discriminating
      # shape: if the lock-and-count ordering were broken, the count would
      # read zero while the insert is in flight and the DROP would destroy
      # the committed row. With the lock, the commit lands first, the fresh
      # count sees it, and the partition is kept with the row intact.
      empty_partition = partition_name(~D[2026-09-01])
      racer = start_tenant_repo(owner_url(), "tenant-c")

      racer_task =
        Task.async(fn ->
          # The insert runs through the parent (the store's only write path)
          # and holds its transaction open. The query addresses the repo PID
          # explicitly — the same shape the store's dispatched queries use,
          # so it joins the racer's transaction connection.
          previous = Repo.get_dynamic_repo()
          Repo.put_dynamic_repo(racer)

          result =
            Repo.transaction(fn ->
              query!(
                racer,
                "INSERT INTO \"#{prefix}\".\"ash_onetime_response_payloads\" VALUES ($1, $2, $3::uuid, $4)",
                ["tenant-c", ~D[2026-09-20], Ecto.UUID.dump!(Ecto.UUID.generate()), <<0, 1>>]
              )

              Process.sleep(600)
            end)

          Repo.put_dynamic_repo(previous)
          result
        end)

      Process.sleep(150)

      put_repo(substrate.owner_repo)

      result = Postgres.cleanup(Postgres.for_repo(Repo, prefix), 100, 4)

      Repo.put_dynamic_repo(Repo)
      {:ok, _} = Task.await(racer_task, 5_000)

      assert {:ok, %{payload_partitions: 0, payload_partitions_kept: 2}} = result
      assert partition_exists?(prefix, occupied_partition)
      assert partition_exists?(prefix, empty_partition)
      assert scalar!(Repo, "SELECT count(*) FROM #{prefix}.\"#{empty_partition}\"", []) == 1

      stop_repo(racer)
    end

    @tag @rls_prune_tier
    test "a default-privileged runtime role reads a rolled child directly and sees only its tenant" do
      substrate = rls_substrate!()
      %{prefix: prefix} = install_rls_store!(install_context(substrate))

      put_repo(substrate.owner_repo)

      # The two-login model: the runtime role gets USAGE on the schema, SELECT
      # on the parent tables (for normal traffic), and — altered BY the owner,
      # because default privileges bind to the grantor — SELECT on everything
      # the owner creates from now on. Children are then directly queryable by
      # name; without child-level policies that is a cross-tenant read (the
      # class of leak i-1 proved November 8).
      query!(Repo, ~s{GRANT USAGE ON SCHEMA "#{prefix}" TO #{substrate.app_role}}, [])

      for table <- ["ash_onetime_idempotency_claims", "ash_onetime_response_payloads"] do
        query!(Repo, ~s{GRANT SELECT ON "#{prefix}"."#{table}" TO #{substrate.app_role}}, [])
      end

      query!(
        substrate.owner_repo,
        ~s{ALTER DEFAULT PRIVILEGES IN SCHEMA "#{prefix}" GRANT SELECT ON TABLES TO #{substrate.app_role}},
        []
      )

      {:ok, _} = Postgres.roll_partitions(Postgres.for_repo(Repo, prefix), 15)

      Repo.put_dynamic_repo(Repo)

      child = partition_name(shift_months(Date.beginning_of_month(Date.utc_today()), 14))
      assert partition_exists?(prefix, child)

      tenant_a = start_tenant_repo(app_url(), "tenant-a")
      tenant_b = start_tenant_repo(app_url(), "tenant-b")

      for tenant <- [tenant_a, tenant_b] do
        query!(
          tenant,
          "INSERT INTO \"#{prefix}\".\"ash_onetime_response_payloads\" VALUES ($1, $2, $3::uuid, $4)",
          [
            if(tenant == tenant_a, do: "tenant-a", else: "tenant-b"),
            shift_months(Date.utc_today(), 14),
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            <<0, 1>>
          ]
        )
      end

      # Direct, by-name reads of the child: each runtime session sees exactly
      # its own tenant's rows. The superuser (unfiltered by policy) sees both.
      assert scalar!(tenant_a, "SELECT count(*) FROM \"#{prefix}\".\"#{child}\"", []) == 1
      assert scalar!(tenant_b, "SELECT count(*) FROM \"#{prefix}\".\"#{child}\"", []) == 1
      assert scalar!(Repo, "SELECT count(*) FROM \"#{prefix}\".\"#{child}\"", []) == 2

      stop_repo(tenant_a)
      stop_repo(tenant_b)
    end
  end

  # ------------------------------------------------------------------
  # Substrate helpers
  # ------------------------------------------------------------------

  defp database_url do
    Application.fetch_env!(:ash_onetime, Repo)[:url]
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

  # Rebuilds a login URL's userinfo for an ad-hoc role created by this test:
  # the password was generated with random_password/0 and minted into the
  # role above, so the URL never leaves the process dictionary.
  defp credential(role) do
    "#{role}:#{URI.encode_www_form(Process.get({__MODULE__, :bare_password}))}"
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
      _ = SQL.query(Repo, "DROP EVENT TRIGGER IF EXISTS ash_onetime_test_no_alter", [])
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
    install_rls_store_with_matrix!(tier1)
  end

  defp install_rls_store_with_matrix!(context) do
    unique = Ecto.UUID.generate() |> String.replace("-", "")
    prefix = "ash_onetime_rls_#{unique}"
    temporary = Path.join(System.tmp_dir!(), "ash_onetime_rls_#{unique}")
    migrations = Path.join(temporary, "migrations")

    Mix.Task.reenable("ash_onetime.gen.migrations")

    arguments = [
      "--repo",
      inspect(Repo),
      "--migrations-path",
      migrations,
      "--timestamp",
      "20261109000000"
    ]

    GenerateMigrations.run(arguments)

    [install_path] = Path.wildcard(Path.join(migrations, "*_install_ash_onetime.exs"))
    [{install_module, _}] = Code.compile_file(install_path)
    install_version = 2_026_110_900_000

    install_repo = context[:install_repo] || Repo

    try do
      provision_schema!(context, install_repo, prefix)
      :ok = Ecto.Migrator.up(Repo, install_version, install_module, prefix: prefix, log: false)
      harden_row_security!(context, install_repo, prefix)

      Map.merge(context, %{prefix: prefix, temporary: temporary})
    after
      Repo.put_dynamic_repo(Repo)
    end
  end

  # The migrating role owns its schema (as in a real consumer install). The
  # shared instance's own role creates its schema directly.
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

    # The runtime role needs schema USAGE for every object it touches — the
    # two-login model includes it alongside the default privileges.
    if context[:app_role] do
      query!(Repo, ~s{GRANT USAGE ON SCHEMA "#{prefix}" TO #{context.app_role}}, [])
    end

    Repo.put_dynamic_repo(install_repo)
  end

  # FORCE row-level security with a per-tenant policy, past-month partitions,
  # and the application role's ordinary DML over the store.
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

  # The install-side twin of Postgres.copy_parent_row_security/3: children
  # are directly queryable by name, so they carry the parent's flags and
  # policies. This is the two-login isolation the b-1 change pins.
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
        ddl := format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', child_oid);
        EXECUTE ddl;
        ddl := format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', child_oid);
        EXECUTE ddl;

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
    tenant_repo = start_tenant_repo(database_url(), logical_partition)

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

  # A completed claim past its retention horizon, with the one payload row
  # the delete-guard trigger demands on deletion. The insert path here is
  # direct SQL with Elixir-side hashes (the store would mint real ones we do
  # not need for cleanup).
  defp insert_completed_claim!(prefix, logical_partition, response_partition_date) do
    tenant_repo = start_tenant_repo(database_url(), logical_partition)
    claim_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    hash = :crypto.hash(:sha256, claim_id)

    query!(
      tenant_repo,
      """
      INSERT INTO "#{prefix}"."ash_onetime_idempotency_claims"
        (id, logical_partition, operation_hash, scope_hash, key_hash, fingerprint, state,
         response_partition, response_codec, response_digest, admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $3, $3, $3, 'complete',
              $4::date, 'json', $3,
              transaction_timestamp() - interval '2 hours',
              transaction_timestamp() - interval '1 hour',
              transaction_timestamp() - interval '2 hours')
      """,
      [claim_id, logical_partition, hash, response_partition_date]
    )

    query!(
      tenant_repo,
      """
      INSERT INTO "#{prefix}"."ash_onetime_response_payloads"
        (logical_partition, partition_date, claim_id, encoded_response)
      VALUES ($1, $2::date, $3::uuid, $4)
      """,
      [logical_partition, response_partition_date, claim_id, <<0, 1, 2, 3>>]
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

  defp force_flagged?(prefix, partition) do
    result =
      SQL.query!(
        Repo,
        """
        SELECT c.relforcerowsecurity
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2
        """,
        [prefix, partition]
      )

    result.rows == [[true]]
  end

  defp scalar!(repo, sql, params) do
    result = SQL.query!(repo, sql, params)
    [[value]] = result.rows
    value
  end

  defp drop_quietly(prefix) do
    Repo.put_dynamic_repo(Repo)
    _ = SQL.query(Repo, ~s{DROP SCHEMA IF EXISTS "#{prefix}" CASCADE}, [])
    :ok
  end
end
