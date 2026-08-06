# Getting started

`ash_onetime` targets Elixir `~> 1.20` (tested on 1.20.2), Erlang/OTP 29, Ash `>= 3.29.3`,
AshPostgres 2, and PostgreSQL 18.

## Test database

The suite fails closed unless `DATABASE_URL` points to the dedicated database and port:

```sh
docker run --name ash-onetime-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=ash_onetime_test \
  -p 127.0.0.1:18841:5432 \
  -d postgres:18

export DATABASE_URL=ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test
mix deps.get
mix test
```

Before creating the container, verify that neither a container named
`ash-onetime-postgres` nor a listener on port `18841` already exists. Reuse the existing
dedicated container; do not start a second database on another port.

## Package dependency

The package is not published yet. After publication, consumers will add the released
Hex requirement and enable `AshOnetime.Resource` on individual Ash resources.

## Resource DSL

Protection is declared per action. Strategy and scope have no defaults:

```elixir
use Ash.Resource,
  domain: MyApp.Domain,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshOnetime.Resource]

onetime do
  protect :charge do
    strategy :idempotency
    scope [{:attribute, :account_id}, {:static, "charge"}]
    key {:client, :idempotency_key}
    fingerprint arguments: [:amount], attributes: [:account_id]
    response MyApp.ChargeCodec, fields: [:id, :status], classify: MyApp.ChargeClassifier
    retention {24, :hour}
  end

  protect :redeem do
    strategy :one_time_nonce
    scope [{:tenant, MyApp.TenantScope}, {:static, "redeem"}]
    key {:verified, :proof, MyApp.RedemptionVerifier}
    window max_age: {10, :minute}, clock_skew: {15, :second}
  end
end
```

Only AshPostgres actions with `transaction? true` can be protected. Read actions,
duplicate protections, unsafe replay hooks, unresolved scope/key references, reserved
verification inputs, and strategy-incompatible options fail during resource compilation
before the resource module loads. Idempotency requires a fingerprint, classified response,
and positive retention. One-time nonces accept only verified or minted key sources and have
no stored-response, external-effect, or configurable failure-direction surface.

See the generated [resource DSL reference](dsls/DSL-AshOnetime.Resource.md) for the complete
option shape.
