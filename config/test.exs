import Config

database_url = System.get_env("DATABASE_URL")

config :ash, :disable_async?, true

config :ash_onetime,
  ecto_repos: [AshOnetime.Test.Repo],
  allow_clock_override: true,
  allow_admission_override: true

config :ash_onetime, AshOnetime.Test.Repo,
  url: database_url,
  priv: "test/support/priv",
  snapshots_path: "test/support/priv/resource_snapshots",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 5_000,
  queue_interval: 10_000

config :logger, level: :warning
