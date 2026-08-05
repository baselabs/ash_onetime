# Resource DSL

Add `AshOnetime.Resource` to an AshPostgres resource, then protect each effectful,
transactional action explicitly. There is no default strategy and no implicit scope.

```elixir
use Ash.Resource,
  domain: MyApp.Domain,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshOnetime.Resource]

onetime do
  protect :charge do
    strategy :idempotency
    scope [{:tenant, MyApp.TenantScope}, {:static, "charge"}]
    key [{:client, :request_key}, {:attribute, :account_id}]
    fingerprint arguments: [:amount], attributes: [:account_id]
    response MyApp.ChargeCodec, fields: [:id, :status], classify: MyApp.Classifier
    retention {24, :hour}
    on_definite_store_failure :fail_closed
    limits max_cache_entry_bytes: 1_048_576
  end

  protect :redeem do
    strategy :one_time_nonce
    scope [{:static, "redemption"}]
    key {:verified, :proof, MyApp.Verifier}
    window max_age: {10, :minute}, clock_skew: {15, :second}
  end
end
```

## Closed component types

Scope accepts `{:static, value}`, `{:argument, name}`, `{:attribute, name}`, and
`{:tenant, resolver}`. A runtime resolver must return nonempty canonical data; a missing
tenant or argument is an error, never a global scope.

Keys accept `{:client, argument}`, `{:argument, argument}`, `{:external, argument}`,
`{:attribute, attribute}`, `{:verified, argument, verifier}`, and `{:minted, minter}`.
Nonce protection requires only verified or minted sources. Verification callbacks return
`AshOnetime.Verified`; action input cannot supply trusted timestamps, algorithms, or
verification state. Choose either verified sources or one minted source for a nonce key;
a minted source cannot be combined with another source because fresh minting would change
the authoritative replay key on every attempt.

Idempotency requires `fingerprint`, `response`, and positive `retention`. The response
codec receives an explicit field allowlist and a classifier that chooses store, reject,
or rollback. `on_definite_store_failure :execute_untracked` is available only to
idempotency and only for proof that admission was never dispatched. `limits` bounds
canonical input and cache payload work.

Nonce requires `window` and deliberately has no response, retention, external-effect, or
failure-direction option. `external_effect` is idempotency-only and requires a recoverable
adapter.

Compile-time validation rejects read or nontransactional actions, duplicate protections,
empty scope, missing references, reserved verification inputs, unsafe replay callbacks,
excessive bounds, and every strategy-incompatible option before the resource loads.
Use `AshOnetime.Resource.Info.protection/2` and `protections/1` for normalized read-only
introspection.

The generated [Spark DSL reference](dsls/DSL-AshOnetime.Resource.md) is the exact option
shape.
