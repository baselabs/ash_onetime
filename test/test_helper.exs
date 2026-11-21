# Tests require a dedicated loopback PostgreSQL instance.
# DATABASE_URL must use ecto, 127.0.0.1, postgres, and the dedicated test database.
# PGPORT may vary by machine, but the default port 5432 is refused.
# Never point tests at a server carrying unrelated databases.
# The URL guard validates the target shape, not other server contents.
:ok =
  :logger.add_primary_filter(:ash_onetime_native_diagnostics, {
    &AshOnetime.Test.ExitBoundary.Diagnostics.logger_filter/2,
    nil
  })

database_url = System.fetch_env!("DATABASE_URL")

parsed_url =
  case URI.new(database_url) do
    {:ok, parsed} -> parsed
    {:error, _reason} -> raise "DATABASE_URL must be a valid dedicated test database URI"
  end

%URI{scheme: scheme, userinfo: userinfo, host: host, port: port, path: path} = parsed_url

[user | _] = String.split(userinfo || "", ":")

dedicated_target? =
  scheme == "ecto" and user == "postgres" and host == "127.0.0.1" and
    path == "/ash_onetime_test" and is_integer(port) and port != 5432

unless dedicated_target? do
  raise """
  DATABASE_URL must target the dedicated ash_onetime_test PostgreSQL on \
  127.0.0.1 under the postgres user, on a non-default port — see .env.example (PGPORT)
  """
end

case AshOnetime.Test.Application.start(:normal, []) do
  {:ok, _supervisor} -> :ok
  _error -> raise "the dedicated test fixture application did not start"
end
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

ExUnit.configure(
  formatters:
    Enum.map(ExUnit.configuration()[:formatters], fn
      ExUnit.CLIFormatter -> AshOnetime.Test.TestFormatter
      formatter -> formatter
    end)
)
