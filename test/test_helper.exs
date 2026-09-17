# Fail closed against a wrong database target: the harness may only ever run
# against the dedicated loopback instance. The PORT is deliberately flexible —
# each machine picks a collision-free port via .env (PGPORT), and CI pins
# 18841 — but every other dimension is fixed: the ecto scheme, the postgres
# user, the loopback host, and the dedicated database name. The default port
# 5432 is refused: a default-port listener is a shared local instance, not the
# dedicated one.
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
  #{inspect(database_url)} — see .env.example (PGPORT)
  """
end

{:ok, _supervisor} = AshOnetime.Test.Application.start(:normal, [])
AshOnetime.Test.Migration.assert_isolated_database!()
Ecto.Adapters.SQL.Sandbox.mode(AshOnetime.Test.Repo, :manual)

ExUnit.start()
