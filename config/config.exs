import Config

# The Elixir window in mix.exs cannot see the OTP build: System.version/0 does
# not encode it, so the same Elixir compiled against a foreign OTP passes
# Mix's check while producing incompatible BEAMs that poison shared _build/PLT
# state. system_info(:otp_release) returns a charlist — the to_string/1 is
# mandatory or the assert always raises. Like the Elixir window, this is a
# SUPPORTED SET, not a pin: every release listed here has a CI leg proving it
# (.github/workflows/ci.yml); the set grows only in the same commit that adds
# the leg. Repo-local only — config/ is excluded from the Hex package, so
# consumers' own OTP choices are untouched.
supported_otp_releases = ["28", "29"]
running_otp = to_string(:erlang.system_info(:otp_release))

unless running_otp in supported_otp_releases do
  raise "ash_onetime development requires Erlang/OTP #{Enum.join(supported_otp_releases, " or ")}; running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end

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
