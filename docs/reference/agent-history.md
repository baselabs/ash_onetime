# Agent instruction history

Text moved byte-for-byte out of `AGENTS.md` on October 28, 2026, when the owner ruled that
process is sized to the risk of each change. Historical record only; not binding.

## From AGENTS.md: Required checks (superseded framing)

## Required checks

Run these commands before reporting a change complete:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
MIX_ENV=test mix dialyzer
mix deps.audit
mix hex.audit
mix hex.build
```

## From AGENTS.md: Boundaries, platform bullet (original wording)

- macOS and Linux are the required developer platforms: a repo that cannot clone, build, and run its gate battery on both, on a developer machine, is a failure. Windows developers use WSL2 (clone inside the WSL filesystem, not under `/mnt/c`), which is the Linux path; no native-Windows developer path is maintained or claimed (owner direction, October 4, 2026). This is a developer-setup property, not a CI leg; CI runs on Linux only. Gates run in Elixir (`.exs`), never POSIX shell; keep `.gitattributes` (`* text=auto eol=lf`) intact.
