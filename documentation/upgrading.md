# Upgrading

Version-to-version migration notes. `ash_onetime` follows semantic versioning: breaking DSL
or contract changes bump the minor version (the library is pre-1.0), and each breaking
change lands here with the exact edit to make.

The published package is [v0.1.0](https://hex.pm/packages/ash_onetime). Set your dependency
to the minor range to pick up patches automatically and review this page on each minor bump:

```elixir
{:ash_onetime, "~> 0.1"}
```

## Forward response-partition maintenance (apply once to existing installs)

Two data-layer fixes shipped for the response store: the `response_partition` index (cleanup's
partition-empty check was a full scan) and forward monthly partition creation (payloads past
the install window routed to `_default` and were never dropped, silently defeating bounded
retention). Greenfield installs on the current version get both automatically from the install
migration. **Existing installs should generate and run the forward migration once:**

```sh
mix ash_onetime.gen.roll_forward --repo MyApp.Repo --months 18
mix ecto.migrate
```

It adds the index, back-fills the elapsed+forward partitions, and drains past-retention
payloads stranded in `_default`. After that, schedule `mix ash_onetime.roll_partitions` (or
`AshOnetime.Oban.PartitionWorker`) on a cadence ahead of your retention horizon — see
[Operations](operations.md#forward-response-partitions). This is additive (no DSL/contract
change) and does not require a dependency version bump.

## v0.2.0 — single `limits` surface (planned)

The dual `limits` surface collapses to one `protect`-level vocabulary. Response-size limits
can no longer be declared on the `response` entity; declare them on `protect` instead.

**Before (v0.1):**

```elixir
protect :charge do
  strategy :idempotency
  # ...
  response MyApp.ChargeCodec,
    fields: [:id, :status],
    classify: MyApp.ChargeClassifier,
    limits: [max_response_bytes: 8_388_608]
end
```

**After (v0.2):**

```elixir
protect :charge do
  strategy :idempotency
  # ...
  response MyApp.ChargeCodec, fields: [:id, :status], classify: MyApp.ChargeClassifier
  limits max_response_bytes: 8_388_608
end
```

The `protect limits:` option accepts the full 11-key union — the key/verification/cache
keys (`max_key_bytes`, `max_token_bytes`, `max_scope_components`, `max_fingerprint_bytes`,
`verifier_timeout_ms`, `max_cache_entry_bytes`) and the response-payload keys
(`max_response_bytes`, `max_response_depth`, `max_response_nodes`, `max_response_entries`,
`max_response_scalar_bytes`). All keys are validated at compile time; move any
`response ..., limits: [max_response_*: ...]` onto `protect ..., limits: [...]`.

This change is additive in coverage (no limit is lost) and removes a redundant configuration
surface where two places could spell overlapping limits.

## Between releases

Non-breaking additions (new optional integrations, new introspection helpers, new guides)
ship in patch or minor releases and need no migration. Check the
[CHANGELOG](https://github.com/baselabs/ash_onetime/blob/main/CHANGELOG.md) for the full list
per release.

If you depend on a private (non-documented) module or function, it may change in any release
— the public contract is the documented DSL, the modules in the API reference, and the
behaviours (`AshOnetime.Codec`, the `classify/2` contract on `AshOnetime.ResponseClassifier`,
verification callbacks returning `AshOnetime.Verified`).
