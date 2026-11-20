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
  # Keep unrelated idle-pool pings outside a boundary observation.
  idle_interval: 3_600_000,
  # Kernel keepalives keep the idle installation pool connected while observations
  # use their own pool, without adding protocol pings to those observations.
  parameters: [
    tcp_keepalives_idle: "60",
    tcp_keepalives_interval: "10",
    tcp_keepalives_count: "5"
  ],
  queue_target: 5_000,
  queue_interval: 10_000

config :logger, level: :warning
