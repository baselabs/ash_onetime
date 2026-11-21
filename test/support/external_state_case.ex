defmodule AshOnetime.Test.ExternalStateCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  import ExUnit.Assertions

  alias AshOnetime.Store.{Claim, Postgres}
  alias AshOnetime.Test.{ClusterIsolation, Repo}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator

  using do
    quote do
      import AshOnetime.Test.ExternalStateCase
      alias AshOnetime.Store.{Claim, Postgres, Result}
      alias AshOnetime.Test.Repo
      alias Ecto.Adapters.SQL
    end
  end

  setup_all context do
    Sandbox.mode(Repo, :auto)
    ClusterIsolation.assert_per_run_server!()
    suffix = String.replace(Ecto.UUID.generate(), "-", "")
    schema = "ao_effect_#{suffix}"
    owner = "ao_effect_owner_#{suffix}"
    runtime = "ao_effect_runtime_#{suffix}"
    maintainer = "ao_effect_maintainer_#{suffix}"
    migrator = "ao_effect_migrator_#{suffix}"
    roles = [owner, runtime, maintainer, migrator]

    credentials =
      Map.new(
        [runtime, migrator, maintainer],
        &{&1, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}
      )

    on_exit(fn ->
      SQL.query!(Repo, "DROP SCHEMA IF EXISTS #{q(schema)} CASCADE", [])
      SQL.query!(Repo, "DROP SCHEMA IF EXISTS #{q(Postgres.routine_schema(schema))} CASCADE", [])

      for role <- roles do
        SQL.query!(Repo, "DROP OWNED BY #{q(role)}", [])
        SQL.query!(Repo, "DROP ROLE #{q(role)}", [])
      end

      Sandbox.mode(Repo, :manual)
    end)

    for role <- roles do
      login =
        if Map.has_key?(credentials, role),
          do: "LOGIN PASSWORD #{literal(credentials[role])}",
          else: "NOLOGIN"

      case SQL.query(Repo, "CREATE ROLE #{q(role)} #{login} NOSUPERUSER NOBYPASSRLS", [],
             log: false
           ) do
        {:ok, _} ->
          :ok

        {:error, %Postgrex.Error{postgres: %{pg_code: code}}} ->
          flunk("role setup failed with #{code}")
      end
    end

    database = SQL.query!(Repo, "SELECT current_database()", []).rows |> hd() |> hd()
    SQL.query!(Repo, "GRANT #{q(owner)} TO #{q(migrator)} WITH INHERIT TRUE, SET TRUE", [])
    SQL.query!(Repo, "GRANT CREATE ON DATABASE #{q(database)} TO #{q(owner)}, #{q(migrator)}", [])
    SQL.query!(Repo, "GRANT SET ON PARAMETER session_replication_role TO #{q(owner)}", [])
    SQL.query!(Repo, "CREATE SCHEMA #{q(schema)} AUTHORIZATION #{q(owner)}", [])
    SQL.query!(Repo, "GRANT USAGE ON SCHEMA #{q(schema)} TO #{q(runtime)}, #{q(maintainer)}", [])

    SQL.query!(
      Repo,
      "ALTER DEFAULT PRIVILEGES FOR ROLE #{q(owner)} IN SCHEMA #{q(schema)} GRANT ALL ON TABLES TO #{q(runtime)}",
      []
    )

    connection_options = %{
      owner: {migrator, credentials[migrator], owner},
      runtime: {runtime, credentials[runtime], runtime},
      maintainer: {maintainer, credentials[maintainer], maintainer}
    }

    c = %{
      schema: schema,
      owner: owner,
      runtime: runtime,
      maintainer: maintainer,
      migrator: migrator,
      connection_options: connection_options
    }

    owner_repo = connection!(c, :owner)
    runtime_repo = connection!(c, :runtime)
    maintainer_repo = connection!(c, :maintainer)

    source =
      Generator.render(Repo,
        maintenance_role: maintainer,
        hash_partitions: context[:hash_partitions]
      )
      |> String.replace(
        "AshOnetime.Test.Repo.Migrations.InstallAshOnetime",
        "AshOnetime.Test.ExternalStateInstall#{suffix}"
      )

    before_maintenance = []

    before_maintenance =
      if context[:force_claim_rls],
        do: [
          "ALTER TABLE #{q(schema)}.ash_onetime_idempotency_claims ENABLE ROW LEVEL SECURITY",
          "ALTER TABLE #{q(schema)}.ash_onetime_idempotency_claims FORCE ROW LEVEL SECURITY",
          "CREATE POLICY runtime_visible ON #{q(schema)}.ash_onetime_idempotency_claims TO #{q(runtime)} USING (true) WITH CHECK (true)"
          | before_maintenance
        ],
        else: before_maintenance

    before_maintenance =
      if context[:outcome_column_update],
        do: [
          "GRANT UPDATE(outcome),REFERENCES(claim_id) ON #{q(schema)}.ash_onetime_effect_outcomes TO #{q(maintainer)}"
          | before_maintenance
        ],
        else: before_maintenance

    source =
      String.replace(
        source,
        "install_maintenance(:fresh)",
        Enum.map_join(before_maintenance, "\n", &("execute(" <> inspect(&1) <> ")")) <>
          "\ninstall_maintenance(:fresh)"
      )

    [{module, _}] = Code.compile_string(source)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    installation = Map.merge(c, %{owner_repo: owner_repo, migration_module: module})
    unless context[:install_in_test], do: :ok = install(installation)

    Map.merge(c, %{
      owner_repo: owner_repo,
      runtime_repo: runtime_repo,
      maintainer_repo: maintainer_repo,
      migration_module: module
    })
  end

  setup c do
    on_exit(fn ->
      if c[:install_in_test] do
        SQL.query!(
          c.owner_repo,
          "DROP SCHEMA IF EXISTS #{q(Postgres.routine_schema(c.schema))} CASCADE",
          []
        )

        SQL.query!(c.owner_repo, "DROP SCHEMA #{q(c.schema)} CASCADE", [])
        SQL.query!(c.owner_repo, "CREATE SCHEMA #{q(c.schema)} AUTHORIZATION #{q(c.owner)}", [])

        SQL.query!(
          c.owner_repo,
          "GRANT USAGE ON SCHEMA #{q(c.schema)} TO #{q(c.runtime)}, #{q(c.maintainer)}",
          []
        )

        SQL.query!(
          c.owner_repo,
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{q(c.schema)} GRANT ALL ON TABLES TO #{q(c.runtime)}",
          []
        )
      else
        SQL.query!(
          c.owner_repo,
          "TRUNCATE #{rel(c, "ash_onetime_idempotency_claims")}, #{rel(c, "ash_onetime_nonce_claims")}, #{rel(c, "ash_onetime_response_payloads")}, #{rel(c, "ash_onetime_effect_outcomes")}",
          []
        )
      end
    end)

    :ok
  end

  def install(c) do
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      Ecto.Migrator.up(Repo, 20_261_116_000_001, c.migration_module, prefix: c.schema, log: false)
    rescue
      error in Postgrex.Error -> {:error, error}
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  def target(c) do
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      Postgres.for_repo(Repo, c.schema)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  def request!(key, options \\ []) do
    {:ok, request} =
      Claim.idempotency(
        [
          operation_hash: :crypto.hash(:sha256, "operation"),
          scope_hash: :crypto.hash(:sha256, "scope"),
          key_hash: :crypto.hash(:sha256, key),
          fingerprint: :crypto.hash(:sha256, "request"),
          retention_seconds: 86_400
        ]
        |> Keyword.merge(options)
      )

    request
  end

  def runtime_transaction(c, action) do
    previous = Repo.put_dynamic_repo(c.runtime_repo)

    try do
      Repo.transaction(action)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  def owner_replica(c, action) do
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      Repo.transaction(fn ->
        SQL.query!(c.owner_repo, "SET LOCAL session_replication_role=replica", [])
        action.()
      end)
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  def age_claim(c, id, options \\ []) do
    retain = Keyword.get(options, :retain, "transaction_timestamp()-interval '1 second'")
    response = Keyword.get(options, :response, "transaction_timestamp()-interval '1 second'")
    previous = Repo.put_dynamic_repo(c.owner_repo)

    try do
      {:ok, _} =
        Repo.transaction(fn ->
          SQL.query!(c.owner_repo, "SET LOCAL session_replication_role=replica", [])
          SQL.query!(c.owner_repo, "SET LOCAL ash_onetime.maintenance='on'", [])

          SQL.query!(
            c.owner_repo,
            "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET admitted_at=transaction_timestamp()-interval '2 days', inserted_at=transaction_timestamp()-interval '2 days', retain_until=#{retain}, response_retain_until=#{response} WHERE id=$1::uuid",
            [Ecto.UUID.dump!(id)]
          )
        end)
    after
      Repo.put_dynamic_repo(previous)
    end

    id
  end

  def record_outcome(c, id, outcome \\ :held, attempt \\ 1) do
    columns = if c[:hash_partitions], do: "operation_hash,logical_partition,", else: ""
    values = if c[:hash_partitions], do: "sha256('operation'::bytea),'global',", else: ""

    SQL.query(
      c.runtime_repo,
      "INSERT INTO #{rel(c, "ash_onetime_effect_outcomes")} (#{columns}claim_id,attempt,outcome,recorded_at) VALUES (#{values}$1::uuid,$2,$3,transaction_timestamp())",
      [Ecto.UUID.dump!(id), attempt, Atom.to_string(outcome)]
    )
  end

  def step(c, name, arguments) do
    SQL.query(c.maintainer_repo, "SELECT #{routine(c, name)}(#{arguments})", [])
  end

  def connection!(c, kind, pool_size \\ 2, options \\ []) do
    {login, password, role} = Map.fetch!(c.connection_options, kind)

    url =
      System.fetch_env!("DATABASE_URL")
      |> URI.parse()
      |> Map.put(:userinfo, URI.encode_www_form(login) <> ":" <> URI.encode_www_form(password))
      |> URI.to_string()

    {:ok, repo} =
      Repo.start_link(
        Keyword.merge(
          [
            name: nil,
            url: url,
            pool: DBConnection.ConnectionPool,
            pool_size: pool_size,
            timeout: 180_000,
            after_connect: fn connection ->
              Postgrex.query!(connection, "SET ROLE #{q(role)}", [])
              Postgrex.query!(connection, "SET ash_onetime.tenant = 'global'", [])
              # Catalog audits must not spend the lock measurement compiling JIT code.
              Postgrex.query!(connection, "SET jit = off", [])
            end
          ],
          options
        )
      )

    Process.unlink(repo)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(repo), do: GenServer.stop(repo, :normal, 5_000)
    end)

    assert SQL.query!(
             repo,
             "SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user OR rolname=session_user",
             []
           ).rows
           |> Enum.all?(&(&1 == [false, false]))

    repo
  end

  def insert_claim(c, options \\ []) do
    id = Keyword.get(options, :id, Ecto.UUID.generate())
    key = Keyword.get(options, :key, id)
    local = Keyword.get(options, :local, false)
    attempt = Keyword.get(options, :attempt, if(local, do: 0, else: 1))

    response_deadline =
      Keyword.get(options, :response_deadline, "transaction_timestamp()+interval '1 hour'")

    sql = """
    INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")}
      (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,effect_local,effect_attempt,
       admitted_at,retain_until,response_retain_until,inserted_at)
    VALUES ($1::uuid,'global',sha256('operation'::bytea),sha256('scope'::bytea),sha256($2::bytea),sha256('request'::bytea),
      'processing',$3,$4,transaction_timestamp(),transaction_timestamp()+interval '1 day',#{response_deadline},transaction_timestamp())
    RETURNING id
    """

    SQL.query!(c.runtime_repo, sql, [Ecto.UUID.dump!(id), key, local, attempt])
    id
  end

  def complete_claim(c, id, options \\ []) do
    date = Keyword.get(options, :date, Date.utc_today())
    hold = Keyword.get(options, :hold)

    SQL.query!(
      c.runtime_repo,
      "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) VALUES ('global',$1,$2::uuid,'response'::bytea)",
      [date, Ecto.UUID.dump!(id)]
    )

    SQL.query!(
      c.runtime_repo,
      "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET state='complete',response_partition=$2,response_codec='test',response_digest=sha256('response'::bytea),hold_reference=$3 WHERE id=$1::uuid",
      [Ecto.UUID.dump!(id), date, hold]
    )

    id
  end

  def query(c, assignment, id),
    do:
      SQL.query(
        c.runtime_repo,
        "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET #{assignment} WHERE id=$1::uuid",
        [Ecto.UUID.dump!(id)]
      )

  def scalar(repo, sql, params \\ []), do: SQL.query!(repo, sql, params).rows |> hd() |> hd()
  def rel(c, name), do: q(c.schema) <> "." <> q(name)
  def routine(c, name), do: q(Postgres.routine_schema(c.schema)) <> "." <> q(name)
  def q(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  def literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
