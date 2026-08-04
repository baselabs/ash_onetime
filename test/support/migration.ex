defmodule AshOnetime.Test.Migration do
  @moduledoc false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

  def assert_isolated_database! do
    %{rows: [[database, port, server_version]]} =
      SQL.query!(
        Repo,
        "SELECT current_database(), current_setting('port'), current_setting('server_version')",
        []
      )

    unless database == "ash_onetime_test" and port == "5432" and
             String.starts_with?(server_version, "18.") do
      raise "database isolation check failed"
    end

    :ok
  end

  def with_sql(up_sql, down_sql, callback) when is_function(callback, 0) do
    SQL.query!(Repo, up_sql, [])

    try do
      callback.()
    after
      SQL.query!(Repo, down_sql, [])
    end
  end

  def install_generated!(options \\ []) do
    unique = Ecto.UUID.generate() |> String.replace("-", "")
    schema = "ash_onetime_test_#{unique}"
    temporary = Path.join(System.tmp_dir!(), "ash_onetime_migration_#{unique}")
    migrations = Path.join(temporary, "migrations")

    arguments =
      ["--repo", inspect(Repo), "--migrations-path", migrations] ++
        if options[:claims] == :hash do
          ["--claims", "hash", "--claim-partitions", Integer.to_string(options[:partitions] || 4)]
        else
          []
        end

    Mix.Task.reenable("ash_onetime.gen.migrations")
    GenerateMigrations.run(arguments)
    [path] = Path.wildcard(Path.join(migrations, "*_install_ash_onetime.exs"))
    [{module, _bytecode}] = Code.compile_file(path)
    version = path |> Path.basename() |> String.slice(0, 14) |> String.to_integer()

    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(Repo, ~s(CREATE SCHEMA "#{schema}"), [])

      for _round <- 1..2 do
        :ok = Ecto.Migrator.up(Repo, version, module, prefix: schema, log: false)
        :ok = Ecto.Migrator.down(Repo, version, module, prefix: schema, log: false)
      end

      :ok = Ecto.Migrator.up(Repo, version, module, prefix: schema, log: false)
    after
      Sandbox.mode(Repo, :manual)
    end

    %{schema: schema, module: module, version: version, path: path, temporary: temporary}
  end

  def uninstall_generated!(installation) do
    Sandbox.mode(Repo, :auto)

    try do
      _result =
        Ecto.Migrator.down(Repo, installation.version, installation.module,
          prefix: installation.schema,
          log: false
        )

      SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "#{installation.schema}" CASCADE), [])
    after
      Sandbox.mode(Repo, :manual)
    end

    :code.purge(installation.module)
    :code.delete(installation.module)
    File.rm_rf!(installation.temporary)
    :ok
  end
end
