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
# ASH_ONETIME_TEST_SERVER names the throwaway server's hostname, which starts with
# "ao-". In GitHub Actions each job service's hostname also carries its run,
# attempt and job or cell, so a server from another run is refused.
# Read the hostname from the connected SERVER, not the client's environment.
# Fail loudly before any cluster-wide grant if the server cannot be proved.
defmodule AshOnetime.Test.ClusterIsolation do
  @moduledoc false

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  def assert_per_run_server! do
    expected = expected_hostname()

    [[hostname]] =
      SQL.query!(
        Repo,
        "SELECT pg_read_file('/etc/hostname')",
        []
      ).rows

    unless is_binary(expected) and String.trim(hostname) == expected do
      raise "cluster-wide grants require a proven per-run PostgreSQL server (ASH_ONETIME_TEST_SERVER)"
    end

    :ok
  end

  defp expected_hostname do
    expected = System.get_env("ASH_ONETIME_TEST_SERVER")

    if is_binary(expected) and String.starts_with?(expected, required_prefix()), do: expected
  end

  defp required_prefix do
    if System.get_env("GITHUB_ACTIONS") == "true" do
      "ao-#{System.fetch_env!("GITHUB_RUN_ID")}-#{System.fetch_env!("GITHUB_RUN_ATTEMPT")}-"
    else
      "ao-"
    end
  end
end
