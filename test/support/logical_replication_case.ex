defmodule AshOnetime.Test.LogicalReplicationCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  import ExUnit.Assertions
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
  import AshOnetime.Test.ExternalStateCase, only: [q: 1, literal: 1, rel: 2, scalar: 2, scalar: 3]

  using do
    quote do
      import AshOnetime.Test.LogicalReplicationCase

      import AshOnetime.Test.ExternalStateCase,
        only: [
          q: 1,
          literal: 1,
          rel: 2,
          scalar: 2,
          scalar: 3,
          insert_claim: 1,
          complete_claim: 2,
          record_outcome: 2,
          record_outcome: 4
        ]

      alias Ecto.Adapters.SQL
    end
  end

  def logical_url! do
    url = System.fetch_env!("ASH_ONETIME_LOGICAL_URL")
    %URI{scheme: scheme, userinfo: userinfo, host: host, port: port, path: path} = URI.parse(url)
    [user | _] = String.split(userinfo || "", ":")

    unless scheme == "ecto" and user == "postgres" and host == "127.0.0.1" and
             path == "/ash_onetime_test" and is_integer(port) and port != 5432 do
      raise "ASH_ONETIME_LOGICAL_URL must target ash_onetime_test as postgres on 127.0.0.1 at a non-default port"
    end

    url
  end

  setup c do
    url = logical_url!()
    suffix = String.replace(Ecto.UUID.generate(), "-", "")
    publisher = "ao_pub_#{suffix}"
    subscriber = "ao_sub_#{suffix}"
    owner = "ao_log_owner_#{suffix}"
    runtime = "ao_log_runtime_#{suffix}"
    maintainer = "ao_log_maint_#{suffix}"
    apply_role = "ao_log_apply_#{suffix}"
    trusted_role = "ao_log_trusted_#{suffix}"
    roles = [owner, runtime, maintainer, apply_role, trusted_role]
    password = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    pgpassfile = Path.join(System.tmp_dir!(), "ao_log_pgpass_#{suffix}")
    on_exit(fn -> File.rm(pgpassfile) end)

    File.open!(pgpassfile, [:write, :exclusive], fn file ->
      File.chmod!(pgpassfile, 0o600)
      uri = URI.parse(url)
      IO.binwrite(file, "127.0.0.1:#{uri.port}:*:#{owner}:#{password}\n")
      [admin_user, admin_password] = String.split(uri.userinfo, ":", parts: 2)
      IO.binwrite(file, "127.0.0.1:#{uri.port}:*:#{admin_user}:#{admin_password}\n")
    end)

    slot = "ao_slot_#{suffix}"
    subscription = "ao_sub_#{suffix}"
    admin = repo!(url)

    # Register first: every connection registered below is closed before this
    # cleanup reconnects and removes precisely this test's databases and slot.
    on_exit(fn ->
      {:ok, cleanup} = start_repo(url)

      try do
        if scalar(
             cleanup,
             "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname=#{literal(subscriber)})"
           ) do
          {:ok, sub} = start_repo(database_url(url, subscriber))

          try do
            SQL.query!(sub, "ALTER SUBSCRIPTION #{q(subscription)} DISABLE", [])
            SQL.query!(sub, "ALTER SUBSCRIPTION #{q(subscription)} SET (slot_name=NONE)", [])
            SQL.query!(sub, "DROP SUBSCRIPTION #{q(subscription)}", [])
          rescue
            e in Postgrex.Error ->
              if e.postgres.pg_code != "42704", do: reraise(e, __STACKTRACE__)
          after
            GenServer.stop(sub)
          end
        end

        eventually!(fn ->
          not scalar(
            cleanup,
            "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='#{slot}' AND active)"
          )
        end)

        SQL.query!(
          cleanup,
          "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name=$1",
          [slot]
        )

        for database <- [subscriber, publisher] do
          SQL.query!(cleanup, "DROP DATABASE IF EXISTS #{q(database)} WITH (FORCE)", [])
        end

        for role <- Enum.reverse(roles) do
          if scalar(
               cleanup,
               "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=#{literal(role)})"
             ) do
            SQL.query!(cleanup, "DROP OWNED BY #{q(role)}", [])
            SQL.query!(cleanup, "DROP ROLE #{q(role)}", [])
          end
        end
      after
        GenServer.stop(cleanup)
      end
    end)

    assert scalar(admin, "SHOW wal_level") == "logical"

    for role <- roles do
      case SQL.query(
             admin,
             "CREATE ROLE #{q(role)} LOGIN PASSWORD #{literal(password)} NOSUPERUSER NOBYPASSRLS",
             [],
             log: false
           ) do
        {:ok, _} ->
          :ok

        {:error, %Postgrex.Error{postgres: %{pg_code: code}}} ->
          flunk("logical role setup failed with #{code}")
      end
    end

    SQL.query!(admin, "GRANT #{q(owner)} TO #{q(trusted_role)} WITH INHERIT TRUE, SET TRUE", [])
    SQL.query!(admin, "GRANT SET ON PARAMETER session_replication_role TO #{q(owner)}", [])

    for database <- [publisher, subscriber] do
      SQL.query!(admin, "CREATE DATABASE #{q(database)} OWNER #{q(owner)} TEMPLATE template0", [])
    end

    common = %{
      schema: "ao_replication",
      owner: owner,
      runtime: runtime,
      maintainer: maintainer,
      hash_partitions: c[:hash_partitions]
    }

    installations =
      for database <- [publisher, subscriber] do
        db_url = database_url(url, database)
        super = repo!(db_url)
        owner_repo = repo!(login_url(db_url, owner, password))
        runtime_repo = repo!(login_url(db_url, runtime, password))
        maintainer_repo = repo!(login_url(db_url, maintainer, password))

        installation =
          Map.merge(common, %{
            owner_repo: owner_repo,
            runtime_repo: runtime_repo,
            maintainer_repo: maintainer_repo,
            admin: super,
            url: db_url
          })

        SQL.query!(owner_repo, "CREATE SCHEMA #{q(common.schema)} AUTHORIZATION #{q(owner)}", [])

        SQL.query!(
          owner_repo,
          "GRANT USAGE ON SCHEMA #{q(common.schema)} TO #{q(runtime)},#{q(maintainer)},#{q(apply_role)},#{q(trusted_role)}",
          []
        )

        SQL.query!(
          owner_repo,
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{q(common.schema)} GRANT ALL ON TABLES TO #{q(runtime)}",
          []
        )

        migrate!(
          installation,
          1,
          Generator.render(Repo,
            maintenance_role: maintainer,
            hash_partitions: c[:hash_partitions]
          )
        )

        migrate!(
          installation,
          2,
          Generator.render_fact_tables(Repo, fact_tables: ["replication_facts"])
        )

        installation
      end

    [pub, sub] = installations

    subscription_repos =
      Map.new([apply_role, trusted_role], &{&1, repo!(login_url(sub.url, &1, password))})
      |> Map.put(owner, sub.owner_repo)

    %{
      pub: pub,
      sub: sub,
      logical_url: url,
      slot: slot,
      subscription: subscription,
      apply_role: apply_role,
      trusted_role: trusted_role,
      subscription_repos: subscription_repos,
      pgpassfile: pgpassfile
    }
  end

  def subscribe!(c, role, options \\ []) do
    tables =
      ~w(ash_onetime_idempotency_claims ash_onetime_nonce_claims ash_onetime_response_payloads ash_onetime_effect_outcomes replication_facts)

    SQL.query!(
      c.pub.admin,
      "CREATE PUBLICATION ao_publication FOR TABLE #{Enum.map_join(tables, ",", &rel(c.pub, &1))} WITH (publish_via_partition_root=true)",
      []
    )

    # A synchronous CREATE SUBSCRIPTION with create_slot=true deadlocks when its
    # publisher is another database in this same cluster.
    SQL.query!(c.pub.admin, "SELECT pg_create_logical_replication_slot($1,'pgoutput')", [c.slot])
    SQL.query!(c.sub.admin, "GRANT pg_create_subscription TO #{q(role)}", [])
    database = scalar(c.sub.admin, "SELECT current_database()")
    SQL.query!(c.sub.admin, "GRANT CREATE ON DATABASE #{q(database)} TO #{q(role)}", [])

    if role == c.apply_role do
      {table, privilege} = Keyword.fetch!(options, :operation)
      # Native apply checks the actual leaf's ACL. UPDATE and DELETE also read
      # the target to find its replica identity; the outcome bound reads claims.
      privileges = if privilege in ["UPDATE", "DELETE"], do: "#{privilege},SELECT", else: privilege
      grants = [{table, privileges}]

      grants =
        if table == "ash_onetime_effect_outcomes" and privilege == "INSERT",
          do: [{"ash_onetime_idempotency_claims", "SELECT"} | grants],
          else: grants

      for {target, privileges} <- grants do
        relations =
          SQL.query!(
            c.sub.admin,
            "WITH RECURSIVE relations(oid) AS (SELECT $1::text::regclass::oid UNION SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON i.inhparent=r.oid) SELECT n.nspname,c.relname FROM relations r JOIN pg_class c ON c.oid=r.oid JOIN pg_namespace n ON n.oid=c.relnamespace",
            [rel(c.sub, target)]
          ).rows

        for [schema, name] <- relations do
          SQL.query!(
            c.sub.admin,
            "GRANT #{privileges} ON #{q(schema)}.#{q(name)} TO #{q(role)}",
            []
          )
        end
      end
    end

    uri = URI.parse(c.pub.url)

    connection =
      "host=127.0.0.1 port=#{scalar(c.pub.admin, "SHOW port")} user=postgres password=postgres dbname=#{String.trim_leading(uri.path, "/")}"

    repo = Map.fetch!(c.subscription_repos, role)
    run_as_owner = Keyword.get(options, :run_as_owner, false)

    SQL.query!(
      repo,
      "CREATE SUBSCRIPTION #{q(c.subscription)} CONNECTION #{literal(connection)} PUBLICATION ao_publication WITH (create_slot=false,slot_name=#{literal(c.slot)},copy_data=false,run_as_owner=#{run_as_owner},disable_on_error=true)",
      []
    )

    eventually!(fn ->
      scalar(c.sub.admin, "SELECT count(*) FROM pg_subscription_rel WHERE srsubstate <> 'r'") == 0 and
        scalar(c.sub.admin, "SELECT count(*) FROM pg_stat_subscription WHERE pid IS NOT NULL") > 0
    end)

    :ok
  end

  def log_checkpoint!(c) do
    [[path, offset]] =
      SQL.query!(
        c.sub.admin,
        "SELECT pg_current_logfile('csvlog'),(pg_stat_file(pg_current_logfile('csvlog'))).size",
        []
      ).rows

    assert is_binary(path), "the logical server must collect csvlog"
    assert is_integer(offset) and offset > 0, "the logical server must expose a non-empty csvlog"
    assert byte_size(scalar(c.sub.admin, "SELECT pg_read_file($1,0,$2)", [path, offset])) > 0

    [[pid]] =
      SQL.query!(
        c.sub.admin,
        "SELECT pid FROM pg_stat_subscription WHERE subid=(SELECT oid FROM pg_subscription WHERE subname=$1) AND relid IS NULL AND pid IS NOT NULL",
        [c.subscription]
      ).rows

    %{path: path, offset: offset, pid: pid}
  end

  def assert_apply_stopped!(c, checkpoint, sqlstate, message) do
    try do
      eventually!(fn ->
        scalar(
          c.sub.admin,
          "SELECT coalesce(sum(apply_error_count),0)::bigint FROM pg_stat_subscription_stats"
        ) > 0
      end)

      eventually!(fn ->
        scalar(
          c.sub.admin,
          "SELECT NOT subenabled FROM pg_subscription WHERE subname=#{literal(c.subscription)}"
        )
      end)

      # Match only bytes written after this case's operation and the exact apply
      # backend observed before it. An error in another session cannot satisfy it.
      eventually!(fn ->
        size = scalar(c.sub.admin, "SELECT (pg_stat_file($1)).size", [checkpoint.path])

        log =
          scalar(c.sub.admin, "SELECT pg_read_file($1,$2,$3)", [
            checkpoint.path,
            checkpoint.offset,
            max(size - checkpoint.offset, 0)
          ])

        Enum.any?(csv_records(log), fn row ->
          # PostgreSQL CSV leaves database_name empty when a background worker
          # has no MyProcPort. The exact PID came from this database's subscription.
          length(row) >= 24 and
            Enum.at(row, 2) in ["", String.trim_leading(URI.parse(c.sub.url).path, "/")] and
            Enum.at(row, 3) == Integer.to_string(checkpoint.pid) and
            Enum.at(row, 11) == "ERROR" and Enum.at(row, 12) == sqlstate and
            String.contains?(Enum.at(row, 13), message) and
            String.contains?(Enum.at(row, 23), "logical replication")
        end)
      end)
    rescue
      error in ExUnit.AssertionError ->
        state =
          SQL.query!(
            c.sub.admin,
            "SELECT subenabled,(SELECT coalesce(sum(apply_error_count),0)::bigint FROM pg_stat_subscription_stats) FROM pg_subscription WHERE subname=$1",
            [c.subscription]
          ).rows

        size = scalar(c.sub.admin, "SELECT (pg_stat_file($1)).size", [checkpoint.path])

        errors =
          scalar(c.sub.admin, "SELECT pg_read_file($1,$2,$3)", [
            checkpoint.path,
            checkpoint.offset,
            max(size - checkpoint.offset, 0)
          ])
          |> csv_records()
          |> Enum.filter(fn row ->
            length(row) >= 24 and
              Enum.at(row, 2) in ["", String.trim_leading(URI.parse(c.sub.url).path, "/")] and
              Enum.at(row, 11) == "ERROR" and
              String.contains?(Enum.at(row, 23), "logical replication")
          end)
          |> Enum.map(fn row ->
            %{pid: Enum.at(row, 3), code: Enum.at(row, 12), message: Enum.at(row, 13)}
          end)

        flunk(
          "assert_apply_stopped!: #{Exception.message(error)}; subscription=#{inspect(state)}; expected_pid=#{checkpoint.pid}; native_errors=#{inspect(errors)}"
        )
    end
  end

  def csv_records(binary), do: csv_records(binary, false, [], [], [])
  defp csv_records(<<>>, _quoted, _field, _fields, rows), do: Enum.reverse(rows)

  defp csv_records(<<"\"\"", rest::binary>>, true, field, fields, rows),
    do: csv_records(rest, true, ["\"" | field], fields, rows)

  defp csv_records(<<"\"", rest::binary>>, quoted, field, fields, rows),
    do: csv_records(rest, not quoted, field, fields, rows)

  defp csv_records(<<",", rest::binary>>, false, field, fields, rows),
    do: csv_records(rest, false, [], [field_value(field) | fields], rows)

  defp csv_records(<<"\n", rest::binary>>, false, field, fields, rows),
    do: csv_records(rest, false, [], [], [Enum.reverse([field_value(field) | fields]) | rows])

  defp csv_records(<<byte, rest::binary>>, quoted, field, fields, rows),
    do: csv_records(rest, quoted, [<<byte>> | field], fields, rows)

  defp field_value(field), do: field |> Enum.reverse() |> IO.iodata_to_binary()

  def force!(installation) do
    for root <- ~w(ash_onetime_idempotency_claims ash_onetime_effect_outcomes),
        [table] <-
          SQL.query!(
            installation.admin,
            "WITH RECURSIVE relations(oid) AS (SELECT $1::text::regclass::oid UNION ALL SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON i.inhparent=r.oid) SELECT oid::regclass::text FROM relations",
            [rel(installation, root)]
          ).rows do
      SQL.query!(installation.admin, "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY", [])
      SQL.query!(installation.admin, "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY", [])
    end
  end

  def seed_completed!(c) do
    id = Ecto.UUID.generate()

    for installation <- [c.pub, c.sub] do
      columns = if installation.hash_partitions, do: "operation_hash,logical_partition,", else: ""
      values = if installation.hash_partitions, do: "sha256('op'::bytea),'global',", else: ""

      replica!(installation, fn ->
        SQL.query!(
          installation.owner_repo,
          "INSERT INTO #{rel(installation, "ash_onetime_idempotency_claims")} (id,operation_hash,scope_hash,key_hash,fingerprint,state,effect_local,effect_attempt,admitted_at,inserted_at,retain_until,response_retain_until,response_partition,response_codec,response_digest) VALUES ($1::uuid,sha256('op'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),'complete',false,2,transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '1 day',transaction_timestamp()-interval '1 day',current_date,'test',sha256('response'::bytea))",
          [Ecto.UUID.dump!(id)]
        )

        SQL.query!(
          installation.owner_repo,
          "INSERT INTO #{rel(installation, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) VALUES ('global',current_date,$1::uuid,'response'::bytea)",
          [Ecto.UUID.dump!(id)]
        )

        SQL.query!(
          installation.owner_repo,
          "INSERT INTO #{rel(installation, "ash_onetime_effect_outcomes")} (#{columns}claim_id,attempt,outcome,recorded_at) VALUES (#{values}$1::uuid,1,'held',transaction_timestamp()),(#{values}$1::uuid,2,'absent_proven',transaction_timestamp())",
          [Ecto.UUID.dump!(id)]
        )
      end)
    end

    id
  end

  def replica!(installation, callback) do
    previous = Repo.put_dynamic_repo(installation.owner_repo)

    try do
      {:ok, result} =
        Repo.transaction(fn ->
          SQL.query!(installation.owner_repo, "SET LOCAL session_replication_role=replica", [])
          callback.()
        end)

      result
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  def legacy_publisher!(c) do
    # The publisher database belongs to this test. Use the shipped install's
    # actual pre-2.0 columns so pg_dump supplies a legacy COPY column list.
    SQL.query!(c.pub.owner_repo, "DROP SCHEMA #{q(c.pub.schema)} CASCADE", [])

    SQL.query!(
      c.pub.owner_repo,
      "DROP SCHEMA #{q(AshOnetime.Store.Postgres.routine_schema(c.pub.schema))} CASCADE",
      []
    )

    SQL.query!(
      c.pub.owner_repo,
      "CREATE SCHEMA #{q(c.pub.schema)} AUTHORIZATION #{q(c.pub.owner)}",
      []
    )

    source =
      AshOnetime.Test.ShippedMigrations.render("v1.1.0", :render, Repo,
        hash_partitions: c.pub.hash_partitions
      )

    migrate!(c.pub, 1, source)
  end

  def eventually!(callback, attempts \\ 1500)

  def eventually!(callback, 0),
    do: assert(callback.(), "logical apply did not reach its expected state")

  def eventually!(callback, attempts) do
    if callback.() do
      :ok
    else
      receive do
      after
        10 -> :ok
      end

      eventually!(callback, attempts - 1)
    end
  end

  def database_url(url, database), do: URI.to_string(%{URI.parse(url) | path: "/" <> database})

  def login_url(url, user, password),
    do: URI.to_string(%{URI.parse(url) | userinfo: user <> ":" <> password})

  def repo!(url) do
    {:ok, repo} = start_repo(url)
    Process.unlink(repo)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(repo), do: GenServer.stop(repo) end)
    repo
  end

  defp start_repo(url),
    do: Repo.start_link(name: nil, url: url, pool: DBConnection.ConnectionPool, pool_size: 2)

  defp migrate!(installation, version, source) do
    module = Module.concat(__MODULE__, "Migration#{System.unique_integer([:positive])}")

    source =
      Regex.replace(~r/defmodule [A-Za-z0-9_.]+ do/, source, "defmodule #{inspect(module)} do",
        global: false
      )

    Code.compile_string(source)

    ExUnit.Callbacks.on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    previous = Repo.put_dynamic_repo(installation.owner_repo)

    try do
      assert :ok =
               Ecto.Migrator.up(Repo, version, module, prefix: installation.schema, log: false)
    after
      Repo.put_dynamic_repo(previous)
    end
  end
end
