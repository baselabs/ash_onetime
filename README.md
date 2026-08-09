# ash_onetime

`ash_onetime` is an Ash extension for explicit keyed-effect semantics. It separates
replay-safe idempotency from collision-rejecting one-time nonces and uses PostgreSQL as the
authoritative admission store.

## When to use this vs. hand-rolled idempotency

Use `ash_onetime` when you need a *correct* admission layer for effectful Ash actions and do
not want to re-derive the failure modes a hand-rolled table-plus-flag approach ships with.

- **The correctness guarantee:** a PostgreSQL-authoritative, once-per-key local effect and
  typed replay within the declared retention boundary. The effect, the admission claim, and
  the encoded response commit or roll back together in the action's existing transaction;
  there is no admission pre-read, so the unique constraint — not application code — decides
  concurrent races. A conflicting fingerprint is terminal and never re-executes.
- **What it replaces:** the bespoke idempotency-key table, the "did this already run?"
  pre-check that races under concurrency, the stored-response schema you have to version and
  re-encode, the fingerprint binding you have to remember to update, and the silent
  double-execution that lands when you forget. Each of these is a class of bug this library
  was built to make impossible at the boundary.
- **When NOT to use it:** read-only or non-transactional actions (the library rejects them),
  resources without AshPostgres (PostgreSQL is the authoritative store; there is no
  fallback), and workloads that need end-to-end exactly-once *delivery* rather than
  once-per-key *local admission* (delivery is a separate concern — see
  [External effects](documentation/external-effects.md)). If you have no effectful action to
  protect, there is nothing to admit.

See [Security model](documentation/security.md) for the authority and fail-closed contract,
and [Recipes](documentation/recipes.md) for end-to-end payment, webhook, and redemption
patterns.

## Status

The package is [published on Hex](https://hex.pm/packages/ash_onetime) as v0.1.0 and the
[source is public](https://github.com/baselabs/ash_onetime). Every protected action chooses
`:idempotency` or `:one_time_nonce` and declares a nonempty scope; there is no default
strategy or global scope fallback. PostgreSQL-authoritative admission, transactional Ash
execution, typed replay, fail-closed nonce spending, signed tokens, external-effect recovery,
bounded cleanup, optional cache/Plug/Oban integrations, and release gates are present.

## Compatibility

- Elixir `~> 1.20` (developed and tested on 1.20.2)
- Erlang/OTP 29
- Ash `>= 3.29.3` and `< 4.0.0` (the whole 3.x line from the 3.29.3 floor up)
- AshPostgres 2
- PostgreSQL 18 for the project test harness

The floor is Ash 3.29.3, not 3.29.0: EEF-CVE-2026-55736 (private action
arguments settable by user input) affects Ash 3.29.0–3.29.2 and is fixed in
3.29.3. Compatibility across the range is verified by the full gate battery —
including `mix hex.audit` — run against the 3.29.3 floor, each intermediate
minor, and the latest published Ash 3.x. `.github/workflows/ci.yml` is
configured to re-run this matrix on every push and pull request. The pinned
development runtime is Elixir 1.20.2 / Erlang/OTP 29 (`.tool-versions`).

## Development

Start the dedicated test database and run the suite as documented in
[CONTRIBUTING.md](CONTRIBUTING.md), then:

```sh
mix deps.get
DATABASE_URL=ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test mix test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete gate battery and
[usage-rules.md](usage-rules.md) for non-negotiable integration boundaries.
The [Getting started guide](documentation/getting-started.md) covers installing the package
and protecting your first action.

## Handling results at the call boundary

A protected action's failure carries a typed `:code` that survives the Ash pipeline, and its
success carries a replayed-vs-fresh signal. Both are observable after `Ash.create/2` /
`Ash.run_action/2` returns:

```elixir
case Ash.create(changeset) do
  {:ok, record} ->
    # 201 on fresh execution (replayed? == false), 200 + Idempotent-Replayed on retry (true).
    status = if AshOnetime.replayed?(record), do: 200, else: 201

  {:error, error} ->
    # The typed code reaches the caller — map it to HTTP.
    case AshOnetime.Error.code(error) do
      :nonce_already_used -> {:conflict, "nonce was already used"}
      :key_reused_with_different_request -> {:conflict, "key reused with a different request"}
      :request_in_progress -> {:conflict, "request is already processing"}
      nil -> {:internal_server_error, "unexpected error"}
    end
end
```

`AshOnetime.replayed?/1` is tri-state: `true` (tracked replay), `false` (tracked fresh), or
`nil` (untracked execution, primitive-return action, or unprotected — see
[Replay](documentation/replay.md)). The full code→HTTP table is in
[Errors](documentation/errors.md).

## Guides

- [Resource DSL](documentation/dsl.md)
- [Idempotency](documentation/idempotency.md)
- [One-time nonces](documentation/one-time-nonces.md)
- [External effects and recovery](documentation/external-effects.md)
- [Replay: fresh vs stored](documentation/replay.md)
- [Errors and HTTP mapping](documentation/errors.md)
- [Operations](documentation/operations.md)
- [Security model](documentation/security.md)
- [Recipes](documentation/recipes.md)
- [Telemetry](documentation/telemetry.md)
- [Upgrading](documentation/upgrading.md)
- [FAQ](documentation/faq.md)
- [Generated Spark DSL reference](documentation/dsls/DSL-AshOnetime.Resource.md)

## License

MIT. See the repository `LICENSE` file.
