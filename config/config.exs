import Config

config :ash,
  default_actions_require_atomic?: true,
  transaction_rollback_on_error?: true

# Ash >= 3.33 refuses to compile resources without an explicit string-length counting
# mode (its remediation shape for EEF-CVE-2026-82752: grapheme counting does not bound
# value size). Codepoints is the recommended mode — it matches how the SQL data layer
# counts, so max_length bounds the size of stored values. Lives here (not test.exs) so
# every environment that ever compiles a resource — including a future resource under
# lib/ — carries it.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
