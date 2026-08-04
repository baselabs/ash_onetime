import Config

database_url = System.fetch_env!("DATABASE_URL")

config :ash, :disable_async?, true

config :ash_onetime,
  ecto_repos: [AshOnetime.Test.Repo]

config :ash_onetime, AshOnetime.Test.Repo,
  url: database_url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
