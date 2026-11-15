import Config

# The test lane provides DATABASE_URL; test/test_helper.exs fails closed without it.
database_url = System.get_env("DATABASE_URL")

config :ash, :disable_async?, true

config :ash_onetime,
  ecto_repos: [AshOnetime.Test.Repo],
  allow_clock_override: true,
  allow_admission_override: true

config :ash_onetime, AshOnetime.Test.Repo,
  url: database_url,
  # The test repo's generated AshPostgres output (the ash-functions extension
  # migration and its snapshot) lives under test/support, outside the Hex
  # package; test_helper.exs runs it so the suite has the same SQL helper
  # functions every consumer's repo installs.
  priv: "test/support/priv",
  snapshots_path: "test/support/priv/resource_snapshots",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  # DBConnection's codel queue dropped the pool's first checkout during the
  # mutation battery's per-mutation boots under host load (observed symptom; the
  # default queue_target is 50ms). Wait patiently instead of dropping at boot.
  queue_target: 5_000,
  queue_interval: 10_000

config :logger, level: :warning
