import Config

database_url =
  System.get_env(
    "DATABASE_URL",
    "ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test"
  )

config :ash, :disable_async?, true

config :ash_onetime,
  ecto_repos: [AshOnetime.Test.Repo],
  allow_clock_override: true,
  allow_admission_override: true

config :ash_onetime, AshOnetime.Test.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
