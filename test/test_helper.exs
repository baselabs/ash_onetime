# Fail closed against a wrong database target: the harness may only ever run
# against the dedicated loopback instance. The PORT is deliberately flexible —
# each machine picks a collision-free port via .env (PGPORT), and CI pins
# 18841 — but every other dimension is fixed: the ecto scheme, the loopback
# host, and the dedicated database name. The user is the dedicated instance's
# `postgres` or the `ash_onetime` role a shared server reserves for this
# library (that role can reach only its own ash_onetime_* databases). The
# default port 5432 is refused: a default-port listener is a shared local
# instance, not the dedicated one.
database_url = System.fetch_env!("DATABASE_URL")

%URI{scheme: scheme, userinfo: userinfo, host: host, port: port, path: path} =
  URI.parse(database_url)

[user | _] = String.split(userinfo || "", ":")

dedicated_target? =
  scheme == "ecto" and user in ["postgres", "ash_onetime"] and host == "127.0.0.1" and
    path == "/ash_onetime_test" and is_integer(port) and port != 5432

unless dedicated_target? do
  raise """
  DATABASE_URL must target the dedicated ash_onetime_test PostgreSQL on \
  127.0.0.1 under the postgres or ash_onetime user, on a non-default port; got: \
  #{inspect(database_url)} — see .env.example (PGPORT)
  """
end

{:ok, _supervisor} = AshOnetime.Test.Application.start(:normal, [])
AshOnetime.Test.Migration.assert_isolated_database!()

# Install the AshPostgres SQL helper functions the test repo declares in
# installed_extensions/0, from the committed codegen output under
# test/support/priv, as every consumer's own extension migration does. In
# :auto mode the migration commits before the per-test sandbox transactions.
# The path is explicit: Ecto would resolve the repo's priv under _build.
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
