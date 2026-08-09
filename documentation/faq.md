# FAQ

Common pitfalls and design questions, with the underlying contract for each. See the linked
guides for the full treatment.

### Idempotency or one-time nonce — which do I want?

They are not interchangeable, and the choice is about what you are protecting against, not
performance.

- **Idempotency** protects an *effectful action* against duplicate execution when the client
  may retry. The first execution runs and stores its result; retries replay the stored
  result. Use it for payments, writes, and any create/update where a network retry must not
  double-charge or double-write.
- **One-time nonce** protects a *request* against replay. The first spend of a verified proof
  succeeds; every reuse is rejected, and there is no stored result to replay. Use it for
  single-use redemptions, anti-replay of a captured request, or anywhere the action must run
  at most once even if the client retries.

The dangerous misuses, called out in [usage-rules.md](../usage-rules.md): never use
idempotency's stored-result replay as anti-replay protection (a replayed idempotent result
is a *success*, not a rejection), and never let a nonce inherit idempotency's optional
untracked failure direction. See [Idempotency](idempotency.md) and
[One-time nonces](one-time-nonces.md).

### How do I design the scope?

Scope is the isolation boundary. Every `protect` block declares a nonempty scope; missing
scope data is an error, never a global fallback. Include every tenant or principal boundary
needed to prevent cross-scope blocking or replay — without the tenant in the scope, one
tenant's idempotency key could collide with another's.

- On `multitenancy strategy :attribute`, put the tenant discriminator in the scope
  (`{:attribute, <tenant_attribute>}` or a `{:tenant, module}` resolver). The library rejects
  a tenant-less scope at compile time for attribute multitenancy because those tenants share
  one set of claim tables.
- Context multitenancy isolates by schema and needs no scope entry for this.
- Add static scope components to namespace distinct operations that share an attribute (e.g.
  `[{:attribute, :account_id}, {:static, "charge"}]` vs `[{:static, "webhook"}]`).

See [Resource DSL](dsl.md) for the closed scope-component types.

### What should the fingerprint bind?

Everything that changes the effect. The idempotency `key` identifies the logical operation
("this client's retry of this charge"); the `fingerprint` binds the request content
("for exactly this amount and account"). A retry with the same key but a *different*
fingerprint is a terminal conflict (`:key_reused_with_different_request`) and never executes
again — it is not a replay.

Bind the fingerprint to all arguments and attributes that change what the action does. For a
charge, that is `amount` (and any fee, currency, or destination). Omitting a varying field
from the fingerprint lets a mutated retry replay a stale result — the silent correctness bug
this library exists to prevent.

### Why does my idempotent action fail with `:request_in_progress`?

Two concurrent requests for the same key raced, and one is mid-flight. This is the
`:conflict` admission result surfaced as the `:request_in_progress` code; it is correct
behavior — the unique constraint decides the race, and the loser is told to wait or retry,
not to execute in parallel. A retry of the same key after the first completes will replay
the stored result.

### Why is `AshOnetime.replayed?/1` returning `nil`?

`replayed?/1` is tri-state: `true` (a tracked replay), `false` (a tracked fresh execution),
or `nil` (untracked execution, a primitive-return action, or an unprotected action). Treat
`nil` as "cannot tell," not as "fresh." A one-time nonce action has no replay signal by
design (there is no stored result), so `nil` is its normal success value. See
[Replay](replay.md).

### My response codec/classifier is rejected at compile time. What's wrong?

The compile-time validator checks the codec and classifier are loaded modules exporting the
right functions before the resource loads. The `response` codec must implement
`AshOnetime.Codec` (`format_tag/0`, `encode/3`, `decode/4` with the documented shapes), and
the classifier must export `classify/2` returning `{:store | :reject | :rollback, value}`.
The `format_tag/0` value must be 1..81 bytes of `[A-Za-z0-9._-]+`. See [Recipes](recipes.md)
for runnable module shapes.

### Can I use this without AshPostgres?

No. Protection is declared on AshPostgres resources whose actions run `transaction? true`,
because PostgreSQL is the authoritative admission store — the unique constraint on the claim
table decides concurrent races, and the effect, claim, and encoded response commit or roll
back together in the action's existing transaction. There is no fallback admission store.

### Is this exactly-once delivery?

No. The guarantee is a PostgreSQL-authoritative, once-per-key *local effect* and typed replay
within the declared retention boundary. Delivery to an external system (a downstream HTTP
call, a message publish) is a separate concern handled by the idempotent
execute/recover protocol for external effects — see [External effects and recovery](external-effects.md).
Describing this as exactly-once *delivery* conflates local admission with end-to-end
delivery, which this library deliberately does not claim.
