# Getting started

`ash_onetime` targets Elixir `~> 1.20` (tested on 1.20.2), Erlang/OTP 29, Ash `>= 3.29.3`,
AshPostgres 2, and PostgreSQL 18. The package is published on
[Hex](https://hex.pm/packages/ash_onetime) (`{:ash_onetime, "~> 0.1.0"}`).

## Install

Add the dependency and install the PostgreSQL objects with Igniter:

```sh
mix igniter.install ash_onetime --repo MyApp.Repo
```

This imports `ash_onetime` into your `.formatter.exs`, writes the deterministic installation
migration, and offers optional Plug (`--with-plug`) and Oban (`--with-oban`) dependencies. See
[Operations](operations.md) for `--claims hash` partitioning and other migration options.

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

## Developing on `ash_onetime` itself

Contributors and library maintainers need the test database harness, which is documented in
[CONTRIBUTING.md](../CONTRIBUTING.md). The suite fails closed unless `DATABASE_URL` points at
the dedicated database on port `18841`; the container is reusable across sessions.
