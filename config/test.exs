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
  pool_size: 10,
  # DBConnection's codel queue dropped the pool's first checkout during the
  # mutation battery's per-mutation boots under host load (observed symptom; the
  # default queue_target is 50ms). Wait patiently instead of dropping at boot.
  queue_target: 5_000,
  queue_interval: 10_000

config :logger, level: :warning
