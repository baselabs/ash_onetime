# Getting started

`ash_onetime` targets Elixir `~> 1.20` (tested on 1.20.2), Erlang/OTP 29, Ash `>= 3.31.1`,
AshPostgres 2, and PostgreSQL 18. The package is published on
[Hex](https://hex.pm/packages/ash_onetime) (`{:ash_onetime, "~> 0.5"}`).

## Install

Add the dependency and install the PostgreSQL objects with Igniter:

```sh
mix igniter.install ash_onetime --repo MyApp.Repo
```

This imports `ash_onetime` into your `.formatter.exs`, writes the deterministic installation
migration, and offers optional Plug (`--with-plug`) and Oban (`--with-oban`) dependencies.
Pass `--resource MyApp.MyResource` (repeatable) to wire `AshOnetime.Resource` into a resource
and scaffold a starter `onetime` block there in the same step. See [Operations](operations.md)
for `--claims hash` partitioning and other migration options.

Then run the migration:

```sh
mix ecto.migrate
```

## Protect your first action

Protection is declared per action on an AshPostgres resource. `AshOnetime.Resource` is an
opt-in extension — add it to each resource you want to protect, then declare a `protect` block
for each protected action. There is no default strategy and no global scope fallback: every
`protect` chooses `:idempotency` or `:one_time_nonce` and declares a nonempty scope.

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
    # `arguments:` binds action arguments; `attributes:` binds resource attributes. Bind both
    # to every input that changes the effect — see Recipes for runnable resource shapes.
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

### DPoP replay fencing (`commit: :independent`)

By default a nonce spend commits inside the action's transaction, so an action-body failure
rolls the spend back — correct for a single-use authenticator whose retry bears a fresh proof.
For [RFC 9449 (DPoP)](https://datatracker.ietf.org/doc/html/rfc9449#section-11.1) §11.1 replay
protection, set `commit: :independent` so the claim commits in its own transaction before the
body runs. A downstream failure then leaves the proof spent for the acceptance window, and a
retry with the same `jti` is rejected with `:nonce_already_used`:

```elixir
  protect :dpop_protected do
    strategy :one_time_nonce
    scope [{:tenant, MyApp.TenantScope}]
    key {:verified, :dpop_proof, MyApp.DPoPVerifier}
    window max_age: {5, :minute}, clock_skew: {30, :second}
    commit :independent
  end
```

The option is nonce-only (rejected on `:idempotency`) and default-off. See ADR-0003
(Independent-commit nonce) and the
[operations guide](operations.md#dpop-replay-fence-operational-characteristics) for pool-sizing
notes — the independent-commit worker uses a second connection checkout per in-flight request.

Only AshPostgres actions with `transaction? true` can be protected. Read actions,
duplicate protections, unsafe replay hooks, unresolved scope/key references, reserved
verification inputs, and strategy-incompatible options fail during resource compilation
before the resource module loads. Idempotency requires a fingerprint, classified response,
and positive retention. One-time nonces accept only verified or minted key sources and have
no stored-response, external-effect, or configurable failure-direction surface.

See the generated [resource DSL reference](dsls/DSL-AshOnetime.Resource.md) for the complete
option shape.

## Handle the result

A protected action's success carries a replayed-vs-fresh signal, and its failure carries a
typed `:code` that survives the Ash pipeline. Both are observable after `Ash.create/2` /
`Ash.run_action/2` returns:

```elixir
case Ash.create(changeset) do
  {:ok, record} ->
    # 201 on fresh execution (replayed? == false), 200 on retry (replayed? == true).
    status = if AshOnetime.replayed?(record), do: 200, else: 201

  {:error, error} ->
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
[Replay](replay.md)). The full code→HTTP table is in [Errors](errors.md).

## Where to next

- [Idempotency](idempotency.md) and [One-time nonces](one-time-nonces.md) — the two
  strategies in depth.
- [External effects and recovery](external-effects.md) — committing side effects safely.
- [Security model](security.md) — authority, fail-closed behavior, and the guarantees.
- [Livebook notebooks](livebooks/idempotency.livemd) — run each strategy end-to-end in
  Livebook against a real PostgreSQL: [idempotency](livebooks/idempotency.livemd),
  [nonces](livebooks/nonces.livemd), [external recovery](livebooks/external-recovery.livemd).

## Developing on `ash_onetime` itself

Contributors and library maintainers need the test database harness, which is documented in
[CONTRIBUTING.md](../CONTRIBUTING.md). The suite fails closed unless `DATABASE_URL` points at
the dedicated database on port `18841`; the container is reusable across sessions.
