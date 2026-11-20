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

    # rule:maintenance-effective-cluster-isolation
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
