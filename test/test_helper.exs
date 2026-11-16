# Tests require a dedicated loopback PostgreSQL instance.
# DATABASE_URL must use ecto, 127.0.0.1, postgres, and the dedicated test database.
# PGPORT may vary by machine, but the default port 5432 is refused.
# Never point tests at a server carrying unrelated databases.
# The URL guard validates the target shape, not other server contents.
database_url = System.fetch_env!("DATABASE_URL")

%URI{scheme: scheme, userinfo: userinfo, host: host, port: port, path: path} =
  URI.parse(database_url)

[user | _] = String.split(userinfo || "", ":")

dedicated_target? =
  scheme == "ecto" and user == "postgres" and host == "127.0.0.1" and
    path == "/ash_onetime_test" and is_integer(port) and port != 5432

unless dedicated_target? do
  raise """
  DATABASE_URL must target the dedicated ash_onetime_test PostgreSQL on \
  127.0.0.1 under the postgres user, on a non-default port; got: \
  user #{inspect(user)}, host #{inspect(host)} — see .env.example (PGPORT)
  """
end

{:ok, _supervisor} = AshOnetime.Test.Application.start(:normal, [])
AshOnetime.Test.Migration.assert_isolated_database!()

Ecto.Adapters.SQL.Sandbox.mode(AshOnetime.Test.Repo, :auto)

Ecto.Migrator.run(
  AshOnetime.Test.Repo,
  Path.expand("support/priv/migrations", __DIR__),
  :up,
  all: true,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(AshOnetime.Test.Repo, :manual)

ExUnit.start()

# Cluster-wide role/parameter grants can affect unrelated databases even when
# DATABASE_URL names ash_onetime_test. A port or CI flag alone proves nothing.
# Box runs provision an emptyDir PostgreSQL Pod named TEST_ENV_RUN-packages-pg;
# the runner assigns TEST_ENV_RUN before starting it and deletes it on exit.
# CI gives each job service a hostname containing its run, attempt and job/cell.
# Read the hostname from the connected SERVER, not the client's environment.
# Fail loudly before any cluster-wide grant if neither lifecycle can be proved.
defmodule AshOnetime.Test.ClusterIsolation do
  @moduledoc false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  def assert_per_run_server! do
    expected =
      case System.get_env("TEST_ENV_RUN") do
        run when is_binary(run) and run != "" -> run <> "-packages-pg"
        _ -> ci_hostname()
      end

    [[hostname]] =
      SQL.query!(
        Repo,
        "SELECT pg_read_file('/etc/hostname')",
        []
      ).rows

    unless is_binary(expected) and String.trim(hostname) == expected do
      raise "cluster-wide grants require a proven per-run PostgreSQL server (box run or CI job service)"
    end

    :ok
  end

  defp ci_hostname do
    if System.get_env("GITHUB_ACTIONS") == "true" do
      expected = System.get_env("ASH_ONETIME_TEST_SERVER")

      prefix =
        "ao-#{System.fetch_env!("GITHUB_RUN_ID")}-#{System.fetch_env!("GITHUB_RUN_ATTEMPT")}-"

      if is_binary(expected) and String.starts_with?(expected, prefix), do: expected
    end
  end
end
