# Operations

Generate the PostgreSQL installation through Igniter or the deterministic Mix task:

```sh
mix igniter.install ash_onetime --repo MyApp.Repo
mix ash_onetime.gen.migrations --repo MyApp.Repo
mix ecto.migrate
```

The migration creates authoritative idempotency claims, nonce claims, response payload
partitions, collision constraints, cleanup functions, and deletion guards. Claim parents may
be unpartitioned or hash-partitioned by `operation_hash`; response payloads use date
partitions plus a default partition. All identifiers are quoted and every operation keeps the
operation hash in its logical key.

Run bounded cleanup manually or with the optional Oban worker:

```sh
mix ash_onetime.prune --repo MyApp.Repo --batch-size 500
```

Cleanup deletes only claims strictly past their replay/retention horizon, keeps processing
external recovery points, removes response bytes atomically with completed claims, and drops
only empty expired payload partitions after obtaining the required lock. Batch size and
prefix are explicit. Schedule `AshOnetime.Oban.CleanupWorker` only if Oban is installed.

Configure an optional completed-response cache with `config :ash_onetime, :cache, MyCache`
and a bounded `:cache_timeout`. Implement `AshOnetime.Cache`; treat every value as untrusted.
The default `AshOnetime.Cache.None` needs no application configuration or supervision tree.

`AshOnetime.Plug` can copy configured headers into `conn.private.ash_onetime.untrusted`; it
does not verify them. Trusted verification remains inside the protected action.

Telemetry events are `[:ash_onetime, event]`, where event is `:admission`, `:conflict`,
`:replay`, `:fingerprint_mismatch`, `:verification`, `:encoding`, `:cache`, `:cleanup`,
`:external_recovery`, `:store_uncertainty`, or `:untracked_execution`. Metadata is exactly
`strategy`, `resource`, `action`, and `result_class`; measurements are only `duration` or
`count`. Raw keys, scopes, tokens, fingerprints, payloads, signatures, resolver identities,
exceptions, and store results are never telemetry fields.

## Key rotation

Token verification resolves material by the signed key identifier. Add a new key before
using it to sign. Retain every old verification key until the last token it signed is outside
`max_age + clock_skew`, then remove it. An unknown key identifier fails verification; never
fall back silently to a different key.

The supported runtime is Elixir `~> 1.20` (verified on 1.20.2) and Erlang/OTP 29 with
Ash 3.29.x, AshPostgres 2, and PostgreSQL 18. Release checks include the full suite, mutation
matrix, warnings-as-errors documentation, exact Hex archive inspection, and an unpacked
zero-configuration consumer, all run on the runtime pinned in `.tool-versions`; see
[CONTRIBUTING](../CONTRIBUTING.md).
