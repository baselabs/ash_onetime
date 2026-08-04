import Config

config :ash,
  default_actions_require_atomic?: true,
  transaction_rollback_on_error?: true

if config_env() == :test do
  import_config "test.exs"
end
