# Scope note — idempotency vs. anti-replay, and the natural-key case

- **Date:** 2026-08-03
- **Status:** design clarification (refines the 2026-07-01 build handoff; nothing built yet)
- **Origin:** surfaced while reviewing `navyler_cdc`'s S1 wire surface, whose report path
  hand-rolls both an idempotency mechanism and a replay-nonce ledger. Distinguishing the
  two clarifies what `ash_onetime` is — and, deliberately, is **not**.

## The boundary this library must draw

`ash_onetime` is an **idempotency** primitive: *once-per-key, serve-the-stored-result*.
A retry with the same key does not re-execute — it returns the recorded response. The
promise is **retries are safe**.

That is **not** the same as **anti-replay**: *spend-once, reject-on-reuse*. An anti-replay
nonce is a single-use token (usually random, bound to a signature + time window) whose
reuse must **fail**. The promise is **replays are rejected**.

They look structurally similar — both are a `(scope, key)` unique-insert against a keyed
ledger with a TTL — but the semantics are **opposite at the collision**:

| | idempotency (`ash_onetime`) | anti-replay (a nonce) |
|---|---|---|
| key | meaningful / derivable (Idempotency-Key, or natural attrs) | random single-use token |
| on collision | return the **stored response**, no re-exec | **reject** (conflict / 4xx) |
| purpose | make client retries safe | make captured-request replay fail |
| pairs with | an action that may be retried | a signature + replay window |

**Do not let a consumer reach for idempotency to get replay defense.** Serving the stored
response to a replayed *signed* request is a security bug — the replay must be rejected,
not satisfied. Keep this library on the idempotency side of the line and say so in the
moduledoc + usage-rules, so the misuse is named, not just avoided.

## The key can be NATURAL attributes, not only an Idempotency-Key header

The 2026-07-01 handoff frames the key around a client-supplied `Idempotency-Key` header
(Stripe's model). Keep that, but the `navyler_cdc` report path shows a second, equally
first-class mode the design should support explicitly: **the key is a set of domain
attributes** (a natural key), with no client header at all.

There, a reported materialization is idempotent on its **resource identity** —
`(org_id, account_id, asset_definition_id, definition_version, as_of)`. A retry with the
same identity must converge on the one row and append **no** second lineage event; a
concurrent double-submit must resolve to one row. That is textbook once-per-key where the
key is the natural identity, and today it is hand-built as pre-read → create →
catch-unique-violation → retry-once. With this library, that collapses to a declared
`onetime do key [...] end` whose unique constraint resolves the race atomically — no
pre-read, no retry loop.

**Implication for the DSL:** the `key` declaration must accept **resource attributes**
(natural key), not assume a header/`Idempotency-Key` is always present. The "consumer
declares the scope attributes" parameterization already points here; make the
header-less natural-key case a named, tested mode, not an afterthought.

## One lib or two? — recommendation (revised 2026-08-03)

The report path needs *both* mechanisms, so the anti-replay half needs a home. An earlier
draft of this note leaned toward **two libs sharing a store core** (`ash_onetime` +
`ash_nonce`). On reflection that is over-built for a solo greenfield project, and the
recommendation is reversed:

**Build ONE lib — `ash_onetime` — with two explicit strategies (idempotency and
one-time-nonce), selected by a required DSL option.** The name already umbrellas both:
"one-time" covers once-per-key (idempotency) and one-time-use (nonce).

Why one, not two:
- **The substrate is ~75–80% shared** — a `(scope, key)` unique ledger + TTL/eviction +
  partition-drop. The divergence is small and localized: the collision handler
  (return-the-stored-response vs reject) plus one idempotency-only feature (response
  storage + content-hash). That is a strategy branch, not a second architecture.
- **The split's real cost is three repos** — a shared-store lib plus two thin consumers —
  meaning three release cycles, three doc sets, three test suites, for what is one storage
  primitive. That tax is disproportionate here.
- **Start-unified is the low-regret direction.** Unified is cheap to split later (extract
  `ash_nonce` if the nonce side accretes security-specific surface); split-first is
  expensive to merge. You can always factor out; you rarely un-factor.

The one genuine risk of unifying — a consumer reaching for "idempotency" to get replay
defense and having a replayed signed request *served its stored response* (replay
accepted) — is contained by design, not left to discipline:

1. **`strategy` is a REQUIRED declaration, no default** — `strategy :idempotency` or
   `strategy :one_time_nonce`, chosen explicitly per resource/action.
2. **The `:one_time_nonce` strategy exposes NO stored-response / replay surface** — there
   is nothing to serve, so "serve the saved result to a replay" is unreachable in nonce
   mode. The misuse is a compile-shaped impossibility, not a footgun.
3. **Docs + `usage-rules.md` name the boundary and the misuse** (the tables above).
4. **Hex keywords carry both** — "idempotency", "nonce", "anti-replay", "replay
   protection" — so both audiences find the one lib.

## How far into "security machinery" should the one lib go? (2026-08-04)

An earlier draft treated signature binding / replay-window coordination / nonce minting as
signs the nonce side had outgrown the lib and should be extracted. That was too cautious.
Most of that machinery *belongs* in a world-class `ash_onetime`; only one piece has a real
reason to live elsewhere, and it is not "extract the whole nonce concern." Split the three:

- **Nonce minting** (cryptographically-random single-use token) — **build it in.** Trivial,
  cohesive with the nonce strategy, no downside. A world-class nonce primitive mints.
- **Replay-window coordination** (require the signed timestamp within N seconds; evict the
  ledger past the window) — **build it in.** The window is what makes ledger eviction
  *safe* (a token past the window is unreplayable, so forgetting it is sound); the window
  and the ledger are one coupled mechanism. Keeping them together is correct, not scope
  creep.
- **Signature verification** — this is the one to keep out **as an implementation**, for a
  concrete reason, not purity: `ash_webhook_it` already owns signature verification
  (provider-documented canonical strings, per-provider schemes). A second crypto +
  canonical-string implementation here would duplicate it and drift — and duplicated crypto
  is how signature bugs breed. But "keep the crypto out" does not mean "keep signed nonces
  out": verification and spend are separable **in time and concern** — you verify *is this
  authentic?* first, then spend *has this authentic token been seen?* The ledger never
  needs to know *how* the token was authenticated. (navyler's report path already runs
  exactly this order: the `ReportSignature` plug verifies, then hands the nonce to the
  ledger.)

**So: build the signature-binding SEAM, not the crypto.** `ash_onetime` exposes a `verify`
hook that runs before the spend, so signed-nonce flows are first-class in the DSL; the
actual verification is pluggable — supplied by the consumer, or by `ash_webhook_it`'s
signature module, or by a small shared signer. That gives a world-class end-to-end
(mint → sign → verify → spend) without shipping a second copy of the ecosystem's signature
code. The only thing that stays out is a *duplicate* provider-signature implementation.

**Escape hatch (now narrow):** a standalone `ash_nonce` is warranted only if the seam
proves insufficient — e.g. the nonce lifecycle needs to own key custody/rotation itself.
Until that specific pressure is real, one lib with the verify seam covers it.

## Requirements from a signed-capability consumer (2026-08-04)

Reflecting the needs of the concrete consumer this nonce side exists for: a signed-capability
verifier (a bounded-authority / RFC 9449 DPoP-style flow) whose verification core is **pure by
design** — it checks the signature, audience, time window, request binding, and holder proof, and
then, deliberately, does **no** stateful replay reservation. That reservation is the job it hands
to `ash_onetime`. The seam design above is exactly right for it; these five points make it
first-class rather than merely possible.

1. **The `verify` seam must accept a whole external authenticity decision, not just "check one
   signature."** For this consumer, "verify" is the entire capability check, and its output is a
   natural key to spend (the signed invocation id). The seam contract must be *verify → yield the
   spend key → spend*, with the verifier opaque to the ledger — never "the lib verifies a
   provider-signature and derives the token itself." This is the note's stance; state it as a
   contract so the hook's return type is the spend key, and the lib never assumes it authored the
   token.

2. **The replay window must be asymmetric (max-age + clock-skew), not a symmetric "within N
   seconds."** A signed proof binds `issued_at` and is accepted over `[eval − max_age − skew,
   eval + skew]` — past skew on the future side, max-age + skew on the past side. Ledger eviction
   must key off `max_age + skew` (the past horizon), because that is precisely the point past which
   a token is unreplayable and forgetting it is sound. A single-N window either evicts too early
   (admitting a replay inside the real acceptance window) or too late (unbounded ledger). Model the
   window as (max_age, skew), and derive the eviction horizon from it.

3. **Natural-key nonce mode is first-class — minting is one source of the token, not the only
   one.** This consumer's single-use token is a domain value already bound into the signature (an
   invocation UUID the client chose), never a client `Idempotency-Key` header and never lib-minted.
   So `:one_time_nonce` must accept a **consumer-supplied natural key** as the spend key, on equal
   footing with a minted token. The natural-key mode the note makes first-class for idempotency
   must apply to the nonce strategy too.

4. **Spend must compose transactionally with the guarded effect, and reserve BEFORE it.** The
   correct order is reserve-then-effect inside one transaction: the spend commits with the business
   effect, or both roll back. A crash between spend and effect must not leave a burned token with no
   effect (a lost invocation) nor an effect with no spend (a replayable one). Because this runs
   inside an Ash action, the spend must participate in the action's transaction, not open its own.
   State the transactional contract explicitly; it is the difference between an anti-replay
   primitive and a race.

5. **Anti-replay fails CLOSED; idempotency may not — and the guarantee must be STRUCTURAL, not
   just documented.** On store unavailability or an uncertain outcome, `:one_time_nonce` must
   **reject** (a possible replay is never admitted), whereas `:idempotency` on the same uncertainty
   may safely re-execute (a duplicate execution of a retry-safe action is the tolerated cost). Same
   store, opposite fail-direction — the sharpest reason the two strategies are not interchangeable
   at the collision *or* at the failure. **The compile-shaped `strategy` requirement already makes
   the fail-OPEN *collision* behaviour unreachable in nonce mode (no stored-response surface); the
   fail-direction on *failure* needs the same explicitness.** The fail-direction is therefore a
   strategy-**intrinsic** property, NOT a shared/overridable `on_error` option: there must be no
   configuration path by which `:one_time_nonce` fails open. A consumer must never be able to hand a
   nonce the fail-open behaviour of idempotency — by collision *or* by failure.

**Scope correctness (applies to both strategies, load-bearing for the nonce one).** The uniqueness
scope is the quiet-failure surface: too broad and distinct principals collide (a cross-tenant
false conflict, or one tenant burning another's token); too narrow and a real replay slips through
a scope seam. The "consumer declares the scope attributes" parameterization is right; require the
scope to be explicit (no implicit global default) and give it an adversarial test — a foreign-scope
token must NOT be able to satisfy or block a spend in another scope.

**Acceptance criteria these imply (builder need, not happy-path).** The single-use guarantee is
only real if a test proves it under contention: two concurrent spends of the same (scope, key) must
resolve to exactly one winner and one rejection (the unique constraint decides the race, not a
pre-read); the fail-closed property needs a store-error injection proving `:one_time_nonce` rejects
where `:idempotency` re-executes; and the window needs a transient-boundary test (a token at
`eval − max_age − skew` is still rejected on reuse; one past it is evicted) rather than a
settled-state assertion.

## The concrete consumer named: `bounded_authority_protocol` (2026-08-04)

The "signed-capability consumer" above is not hypothetical — it is
`/Users/rp/Developer/BaseLabs/bounded_authority_protocol` (v0.1.0, Apache-2.0, within the
Base/BaseLabs personal IP boundary). It confirms every requirement above from a real API, and it
draws one further boundary line.

- **It is a pure, stateless verifier** — public API `verify_grant/3`, `check_envelope/2` (raw
  grant+holder-proof envelope against server-derived expected context), `decode_grant`/`decode_proof`,
  `request_digest`, and `grant_signing_input`/`proof_signing_input` with **external signature
  assembly**. The package has *zero production deps, no application callback, no supervision tree* —
  so it **structurally cannot** hold a seen-token set. Spend-once is therefore, by construction, the
  caller's job. That caller is `ash_onetime`. This is the cleanest possible confirmation of the
  verify-then-spend split: BA hands over verified facts; `ash_onetime` spends.
- **Its proof already carries the spend key and the window.** The holder-proof payload keys are
  `ath ba_inv ba_op ba_req htm htu iat jti nonce v`; the grant carries `iat nbf exp jti`, and the
  verifier checks `coherent_times?(iat, nbf, exp)`. So the spend key is the proof's `jti` (or
  `ba_inv`, the bound invocation id) — a **consumer-supplied natural token**, never lib-minted — and
  the window is the proof's `iat`/`exp` freshness. This *is* requirement 3 (natural-key nonce) and
  requirement 2 (asymmetric window) instantiated. `ash_onetime` mints only when it owns the token; on
  this path BA owns it and `ash_onetime` spends it.
- **The verify seam's premier consumer.** BA plugs into the `verify` hook exactly as `ash_webhook_it`
  does — a signature `ash_onetime` did not produce. `ash_onetime` must not re-implement grant/proof
  verification any more than it re-implements provider schemes; it delegates to BA and spends the
  `jti`.

### Where NOT to cross-pollinate — BA's consumption chain

BA also defines a **`ConsumptionChain`**: a hash-chained, domain-separated, *ordered* consumption
history (`chain_id`, `commitment`, `previous`, `sequence`; `check_chain/2`). That is richer than flat
spend-once — it is ordered, linked lineage for grants consumed in sequence (delegation/consumption
chains). **`ash_onetime` should stay the flat `(scope, token)` reject-on-reuse ledger and NOT
implement the chain.** The ordered chain is BA-protocol/BA-runtime territory, the same discipline as
"don't re-implement provider signature schemes." Flat spend-once is the primitive; the ordered chain
is a protocol concern that composes *on top of* it.

**Open question (flag, do not decide here):** the BA *runtime* (`bounded_authority`, the private,
not-yet-built B1 lib) needs live storage for its consumption state. Whether it should sit on
`ash_onetime`'s ledger for the flat spend-once layer (while owning the chain semantics itself) is a
real option worth weighing when B1 is designed — but it is the BA runtime's call, not this lib's.

**The live convergence point:** `navyler_cdc`'s report path today hand-rolls EdDSA-sig + a nonce
ledger; its B2 upgrades the envelope to BA-protocol (navyler design §10). At B2 the path becomes
*BA verifies the envelope → `ash_onetime` spends the `jti`* — the two libs composing exactly along
this seam, with navyler the first real consumer of both.

## What to change in the build plan

1. Moduledoc + `usage-rules.md`: state the idempotency-vs-anti-replay boundary explicitly, and
   name **both** misuses with equal weight — the **collision** one (idempotency's stored response
   served to a replay) AND the **failure** one (a nonce inheriting idempotency's fail-open on store
   uncertainty). The failure semantics get the same explicit naming as the collision semantics.
2. DSL: a **required `strategy`** (`:idempotency` | `:one_time_nonce`), and **natural-key**
   (resource-attribute) scoping as a first-class, tested mode alongside the client
   `Idempotency-Key` header mode.
3. Store layer: one reusable keyed-single-use-ledger + TTL core that both strategies
   consume; the `:one_time_nonce` strategy omits the response-storage surface entirely.
   Keep the core's public API clean enough that a future `ash_nonce` extraction is a lift,
   not a rewrite.
4. Nonce strategy — build the full lifecycle IN: **minting** (cryptographically-random
   single-use token) and **replay-window coordination**. Model the window as **(max_age,
   clock_skew)** — an asymmetric acceptance band `[eval − max_age − skew, eval + skew]` — and
   derive the ledger eviction horizon from `max_age + skew`, NOT a single symmetric N (see
   consumer requirement 2). The natural-key nonce mode (consumer-supplied signed token, not only a
   minted one) is a required mode, not minting-only (requirement 3).
5. Signature binding — build a `verify` **seam** that runs BEFORE the spend, so signed
   nonces are first-class, but keep the crypto **pluggable** (consumer-supplied, or
   `ash_webhook_it`'s signature module, or a small shared signer). Do NOT re-implement
   provider-signature verification here — that is `ash_webhook_it`'s job; duplicating it
   breeds drift. The lib owns mint → (verify via seam) → spend; it does not own the crypto. The
   seam's `verify` may be a WHOLE external authenticity decision returning the spend key, not just
   a signature check (requirement 1).
6. Transactional composition — the spend **reserves before the guarded effect and commits with
   it** inside the Ash action's transaction (requirement 4); it must not open its own transaction
   or leave a spend/effect split possible across a crash.
7. Fail-direction — `:one_time_nonce` fails **CLOSED** (store error/uncertainty → reject);
   `:idempotency` may re-execute on the same uncertainty. Make this **strategy-intrinsic and
   NON-overridable** — no shared `on_error` option that spans strategies, so there is no config path
   by which a nonce fails open (the same compile-shaped guarantee as the absent stored-response
   surface). Name the failure semantics in the moduledoc + usage-rules, and test both directions
   including that no option can flip a nonce to fail-open (requirement 5).
8. Scope — require an **explicit** scope declaration (no implicit global default) and add an
   adversarial cross-scope test: a foreign-scope token neither satisfies nor blocks a spend in
   another scope.
9. Acceptance tests are contention/failure-first, not happy-path: concurrent-double-spend →
   exactly one winner; store-error injection → nonce rejects / idempotency re-executes;
   window transient-boundary → token at the horizon still rejected, past it evicted.
