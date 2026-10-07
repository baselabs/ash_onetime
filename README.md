# ash_onetime

[![mutation battery](https://img.shields.io/badge/mutation_battery-red--proven-brightgreen)](CONTRIBUTING.md)

`ash_onetime` is an Ash extension for explicit keyed-effect semantics. It separates
replay-safe idempotency from collision-rejecting one-time nonces and uses PostgreSQL as the
authoritative admissions store.

## What it does

Every protected action declares one strategy and a nonempty scope. PostgreSQL admits exactly
once per key under the declared scope; the unique constraint — not application code — decides
concurrent races. There is no admission pre-read.

- **`:idempotency`** — execute the effect once per key, store the classified response, and
  replay it verbatim on retries within the retention boundary. A conflicting fingerprint
  (same key, different request) is terminal and never re-executes. The effect, the admission
  claim, and the encoded response commit or roll back together in the action's transaction.
- **`:one_time_nonce`** — authenticate a single opportunity and reject every collision. The
  spend lives and dies with the action transaction by default; a retry must bear a fresh proof.
- **`commit: :independent`** (nonce, opt-in, RFC 9449 §11.1) — the DPoP replay fence. The
  nonce claim commits in its own transaction *before* the action body runs, so a downstream
  failure cannot make the proof reusable. A reused proof is rejected with `:nonce_already_used`
  for the acceptance window. Default-off; existing nonce consumers are byte-for-byte unchanged.

Optional, non-admitting surfaces: a response cache, a Plug, Oban workers for cleanup and
forward partition creation, and an external-effect execute/recover protocol for peers that
need to observe or reverse a side effect.

Hosts that already own one authoritative Ecto transaction can use the public
`AshOnetime.Transaction` boundary instead of wrapping an Ash action. It reserves idempotency
and nonce authority inside the caller's existing `READ COMMITTED` transaction, so the claim,
the host effect, and the exact replay bytes commit or roll back together. Logical partitions
isolate tenants or authority planes without importing the host's actor types. See
[Transaction-owned admission](documentation/transaction-owned-admission.md).

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

## Quick start

```elixir
defmodule MyApp.Charge do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "charges"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false, public?: true
    attribute :amount, :integer, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :charge do
      transaction? true
      argument :idempotency_key, :string, allow_nil?: false
      accept [:account_id, :amount]
    end

    # A DPoP-protected redemption: the proof's spend survives a downstream failure.
    action :redeem, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :proof, :string, allow_nil?: false
      run MyApp.Redeem
    end
  end

  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "charge"}, {:attribute, :account_id}])
      key({:client, :idempotency_key})
      fingerprint(attributes: [:account_id, :amount])
      response(MyApp.ChargeCodec, fields: [:id, :account_id, :amount], classify: MyApp.Classifier)
      retention({24, :hour})
    end

    protect :redeem do
      strategy :one_time_nonce
      scope([{:static, "redeem"}])
      key({:verified, :proof, MyApp.ProofVerifier})
      window(max_age: {5, :minute}, clock_skew: {30, :second})
      commit :independent   # RFC 9449 §11.1 replay fence (omit for the default :with_action)
    end
  end
end
```

Install with `mix ash_onetime.install` (Igniter-powered) — it wires the repo, generates the
migration, and sets up the schema. See the
[Getting started guide](documentation/getting-started.md) for the full walkthrough.

## Try it

Runnable Livebook notebooks — one per concern — exercise each strategy against a real
PostgreSQL. Open them in [Livebook](https://livebook.dev), set `DATABASE_URL`, and run every
cell. The nonce notebook performs real Ed25519 signing and verification; the external-effect
notebook uses an independently committed PostgreSQL receipt ledger.

- [Idempotency](documentation/livebooks/idempotency.livemd) — fresh execution, replay, fingerprint conflict.
- [One-time nonces](documentation/livebooks/nonces.livemd) — spend, reuse rejection, and the `commit: :independent` replay fence.
- [External effects and recovery](documentation/livebooks/external-recovery.livemd) — the execute/recover protocol.

See [Security model](documentation/security.md) for the authority and fail-closed contract,
and [Recipes](documentation/recipes.md) for end-to-end payment, webhook, and redemption
patterns.

## Status

This guide targets [v1.3.3](https://hex.pm/packages/ash_onetime/1.3.3), a
security patch for the 1.3 feature line. It raises the published Ash and optional Mint
floors while leaving the 1.3 DSL, public API, database schema, persisted response format,
token wire format, and external-effect behavior unchanged. The 1.3 line predates the
pre-peer claim lock added in 1.4; its external-effect peer must absorb concurrent same-key
execution with atomic operation-key idempotency. Consumers that pin either dependency
should follow [Upgrading](documentation/upgrading.md).

Every protected action chooses `:idempotency` or `:one_time_nonce` and declares a nonempty
scope; there is no default strategy or global scope fallback. Full release history is in
the [CHANGELOG](CHANGELOG.md).

## Compatibility

- Elixir `~> 1.20` (developed and tested on 1.20.4; this requirement admits later 1.x
  releases and excludes 2.0 or newer)
- Erlang/OTP 28 or 29
- Ash `>= 3.34.3` and `< 4.0.0`
- AshPostgres `~> 2.13`, AshSql `~> 0.7 and >= 0.7.1`
- Optional Mint `~> 1.10 and >= 1.10.2` when the host carries the installer HTTP closure
- PostgreSQL 18 for the project test harness. The SQL surface requires PostgreSQL 11+
  (declarative hash/range partitioning with default partitions, `SKIP LOCKED`,
  `pg_advisory_xact_lock(bigint)`); versions below 18 are not exercised by this project's
  CI — treat them as unverified.

The security floors follow [ADR 0004](https://github.com/baselabs/ash_onetime/blob/v1.3.3/docs/adr/0004-security-driven-ash-floor.md).
The October 6, 2026 advisory inventory identifies Ash 3.34.3 as the patched floor:
[EEF-CVE-2026-94201](https://cna.erlef.org/osv/EEF-CVE-2026-94201.html) affects Ash
`>= 3.5.1 and < 3.34.3`; Ash 3.33.11 contains the
[EEF-CVE-2026-93477](https://cna.erlef.org/osv/EEF-CVE-2026-93477.html) fix but remains
affected by EEF-CVE-2026-94201. Mint 1.10.2 backports the fixes for
[EEF-CVE-2026-91043](https://cna.erlef.org/osv/EEF-CVE-2026-91043.html),
[EEF-CVE-2026-92103](https://cna.erlef.org/osv/EEF-CVE-2026-92103.html), and
[EEF-CVE-2026-94194](https://cna.erlef.org/osv/EEF-CVE-2026-94194.html). Optional Igniter
and Mint remain excluded from this package's runtime applications.

## Development

Point `.env` at a dedicated PostgreSQL 18 database you already run, then:

```sh
cp .env.example .env   # set PGPORT and DATABASE_URL to the same non-default port
set -a && . ./.env && set +a
mix deps.get
mix test
```

The supported developer platforms are macOS and Linux. Windows developers use WSL2 and
clone inside the WSL filesystem. See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete
gate battery and [usage-rules.md](usage-rules.md) for integration boundaries.
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
- [Transaction-owned admission](documentation/transaction-owned-admission.md)
- [Replay: fresh vs stored](documentation/replay.md)
- [Errors and HTTP mapping](documentation/errors.md)
- [Operations](documentation/operations.md)
- [Security model](documentation/security.md)
- [Recipes](documentation/recipes.md)
- [Phoenix integration](documentation/phoenix.md)
- [Telemetry](documentation/telemetry.md)
- [Upgrading](documentation/upgrading.md)
- [FAQ](documentation/faq.md)
- Livebook notebooks: [Idempotency](documentation/livebooks/idempotency.livemd) · [Nonces](documentation/livebooks/nonces.livemd) · [External recovery](documentation/livebooks/external-recovery.livemd)
- [Generated Spark DSL reference](documentation/dsls/DSL-AshOnetime.Resource.md)

## License

MIT. See the repository `LICENSE` file.
