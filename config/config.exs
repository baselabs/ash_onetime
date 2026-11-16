import Config

supported_otp_releases = ["28", "29"]
running_otp = to_string(:erlang.system_info(:otp_release))

unless running_otp in supported_otp_releases do
  raise "ash_onetime development requires Erlang/OTP #{Enum.join(supported_otp_releases, " or ")}; running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end

config :ash,
  default_actions_require_atomic?: true,
  transaction_rollback_on_error?: true

# Codepoint string-length counting bounds stored value size and matches the SQL data layer.
# Grapheme counting does not bound bytes and is unsafe for size limits.
# Apply this to every environment that compiles resources.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
