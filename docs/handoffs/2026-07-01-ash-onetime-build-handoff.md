# Historical handoff — build the `ash_onetime` OSS Ash extension

> Historical evidence notice (reconciled 2026-08-05; authority pointers updated 2026-08-22
> at the legacy-forge retirement): this snapshot predates the repository and accepted
> architecture. Live Git, Hex, runtime, the accepted design in
> `docs/design-notes/2026-08-03-scope-idempotency-vs-antireplay.md`, and the accepted
> decisions in `docs/adr/` (ADR-0001 onward supersede the retired forge-era spec and
> implementation plan) are authoritative. Claims below that the
> repository does not exist or that design work remains are stale. Embedded action lists
> are preserved as history and grant no authority to an agent or maintainer. The package is
> now implemented; every greenfield, no-code, or first-action claim below is obsolete.

- **Date:** 2026-07-01 · **regenerated 2026-08-04** from `docs/design-notes/2026-08-03-scope-idempotency-vs-antireplay.md` (the authoritative design; read it before the spec).
- **Repo:** `/Users/rp/Developer/Base/ash_onetime` (greenfield — scaffold only; **no code yet**).
- **For:** a fresh agent with zero conversation history, to build the extension from cold.
- **Origin:** decided in the `core-platform` tech-stack brainstorm as **SD-15**; idempotency is a load-bearing substrate primitive (metering, webhooks, connectors ride it) with **no Ash-native library today** — built as a reusable OSS extension (the `ash_age` model), imported by core_os.
- **Scope (one lib, two strategies over one core):** `:idempotency` (once-per-key, serve-the-stored-result) and `:one_time_nonce` (spend-once, reject-on-reuse). They share ~75–80% of the machinery (a `(scope, key)` unique ledger + TTL + eviction + partition-drop); the divergence is a small, contained strategy branch. The design note carries the full reasoning (why one lib not two, the misuse boundary, how far into signing to go, the concrete consumer); this handoff carries the build shape.
- **Naming (deliberate, 2026-08-03):** `ash_onetime` — renamed from `ash_onetime_it`, `_it` dropped for this lib. Still non-canonical (do NOT take `ash_idempotency`; leave it for an official Ash extension). Carry **"idempotency"**, **"nonce"**, **"anti-replay"**, **"replay protection"** in the hex `description` + keywords so both audiences find it. Sibling `baselabs` libs keep the `ash_*_it` form; this one deliberately does not.
- **Positioning (don't overclaim):** *"retry-safe once-per-key execution + one-time-use tokens"* / *"at-most-once effect"* — **never** bare *"exactly-once"* (that means exactly-once *delivery*, impossible in an async system). Idempotency = the dedup half; at-least-once delivery + dedup = *effectively-once*. "onetime" umbrellas once-per-key (idempotency) and one-time-use (nonce).

---

## Design: one lib, two strategies — the world-class bar

Build this to be **the** reference Ash-native primitive for **single-use keyed effects**. "World-class" is not an adjective here — it is the concrete, testable commitments below. Full reasoning: the design note.

### The two strategies (one core, opposite collision semantics)

Both are a `(scope, key)` unique-insert against one ledger. They differ **only at the collision** — and that difference must be a hard, explicit choice, never a default:

| | `:idempotency` | `:one_time_nonce` |
|---|---|---|
| key | meaningful/derived — a natural key (resource attrs) **or** a client `Idempotency-Key` + content hash | a minted token **or** a consumer-supplied signed token |
| on collision | **return the stored response**, no re-exec | **reject** (conflict) |
| purpose | make client retries safe | make captured-request replay fail |
| stored response | yes | **none — the surface does not exist in this mode** |
| fail-direction on store error | may re-execute (retry-safe) | **fail CLOSED — reject** |

**`strategy` is a REQUIRED DSL declaration, no default.** The misuse that must be *impossible*: a consumer using idempotency for replay defense and having a replayed signed request *served its stored response* (replay accepted = security hole). It is impossible here because `:one_time_nonce` exposes **no stored-response surface** — there is nothing to serve. Name the misuse in the moduledoc + usage-rules.

### The nonce lifecycle — build it ALL in (mint → sign → verify → spend)

- **Minting** — cryptographically-random single-use token. Build it in. But minting is **one** source of the token, not the only one: a consumer-supplied **natural token** (a signed invocation id) is an equal-footing mode (see the signed-capability consumer below).
- **Replay-window** — model it as **(max_age, clock_skew)**, an *asymmetric* acceptance band `[eval − max_age − skew, eval + skew]`, NOT a symmetric N. Derive the **ledger eviction horizon from `max_age + skew`** (the past point past which a token is unreplayable, so forgetting it is sound). A single-N window either evicts too early (admits a replay) or too late (unbounded ledger).
- **Signing — a built-in, batteries-included signer with TWO self-owned schemes** (the "simple signature via a secret key" done right):
  - **`:hmac`** — HMAC-SHA256 over the canonical token payload with a **config/env secret**. Symmetric: the *same* service signs and verifies (internal nonces).
  - **`:ed25519`** — signer holds a **private** key, verifier holds only the **public** key. Asymmetric: an *external* party signs, you verify, and the **verifier cannot forge**.
  - **Security rule the DSL must ENCODE, not leave to the user:** never a shared HMAC secret when an *external* party signs (the signer and anyone who reads your env could forge). Default to `:ed25519` whenever signer ≠ verifier; reserve `:hmac` env-secret for same-service nonces.
- **Verify seam (pluggable) — for signatures/decisions you did NOT produce.** A `verify` hook that runs **before** the spend and returns the **spend key** — the hook may be a *whole external authenticity decision* (an entire capability check), opaque to the ledger, not just "check one signature." Third-party/provider signatures plug in here (delegate to `ash_webhook_it`). **Do NOT re-implement provider-signature schemes** — that is `ash_webhook_it`'s job; duplicated crypto breeds bugs. Built-in signer owns *your own* nonces; the seam owns *someone else's*.

The insight that makes signing composable: **verify and spend are separable in time and concern.** Verify *is this authentic?* first, then spend *has this authentic token been seen?* The ledger never needs to know *how* the token was authenticated.

### The world-class engineering bar (concrete, testable — not adjectives)

- **Correct under concurrency** — two same-key requests racing resolve to exactly one winner via the DB unique constraint (the constraint decides the race, **not a pre-read**); the loser returns the stored result (`:idempotency`) or is rejected (`:one_time_nonce`). Proven with a **real-transaction** test (two committed connections), never the sandbox.
- **Transactional integrity** — the spend **reserves BEFORE the guarded effect and commits with it** inside the Ash action's transaction (never its own). No crash can leave a burned token with no effect, or an effect with no spend.
- **Fail-closed by construction** — required `strategy`; no stored-response surface in nonce mode; external signer ⇒ public-key ⇒ verifier can't forge; on store error/uncertainty `:one_time_nonce` **rejects** while `:idempotency` may re-execute. This fail-direction is **strategy-intrinsic and non-overridable** — no shared `on_error` option, so there is no config path by which a nonce fails open (the same compile-shaped guarantee as the absent stored-response surface). A consumer must never get idempotency's fail-open on a nonce, by collision *or* by failure.
- **Bounded resources** — TTL + eviction + partition-drop; the ledger cannot grow unbounded. Eviction is safe *because* the replay window bounds it.
- **Scope is explicit** — no implicit global default; the consumer declares the scope attributes. Scope is the quiet-failure surface (too broad → cross-tenant false conflict / one tenant burning another's token; too narrow → a replay slips a scope seam).
- **Secure-by-default, fully tunable** — sensible defaults (window, TTL, scheme-by-trust-model), everything overridable; Postgres authoritative, optional cache circuit-breakered so it is never a correctness dependency.
- **Adversarially tested** (contention/failure-first, not happy-path) — concurrent double-spend → exactly one winner + one rejection; store-error injection → nonce rejects / idempotency re-executes; window transient-boundary → a token at `eval − max_age − skew` still rejected on reuse, one past it evicted; content-hash mismatch errors; TTL expiry + reuse-after-expiry; crash-between-effect-and-complete recovery; **forged signature rejected (byte-level tamper)**; cross-scope token neither satisfies nor blocks another scope; wrong-strategy misuse unreachable.

## The concrete consumer + a boundary: `bounded_authority_protocol`

The nonce side exists for a real consumer: `/Users/rp/Developer/BaseLabs/bounded_authority_protocol` (v0.1.0, Apache-2.0; Base/BaseLabs personal IP — within boundary). It is a **stateless, pure verifier** — public API `verify_grant/3`, `check_envelope/2`, `decode_proof`, `request_digest`, `*_signing_input` with **external signature assembly**; zero production deps, no application callback, no supervision tree — so it **structurally cannot** hold a seen-token set. Spend-once is, by construction, the caller's job = `ash_onetime`'s.

- **Its proof already carries the spend key + window** — holder-proof payload `ath ba_inv ba_op ba_req htm htu iat jti nonce v`; grant `iat nbf exp jti`; verifier checks `coherent_times?(iat, nbf, exp)`. The spend key is the proof's `jti`/`ba_inv` (a consumer-supplied natural token, never lib-minted); the window is `iat`/`exp`. This instantiates the natural-key nonce mode + the asymmetric window above.
- **BA is the verify seam's premier consumer** — it plugs into `verify` exactly as `ash_webhook_it` does; `ash_onetime` delegates the capability check to BA and spends the `jti`.
- **Where NOT to cross-pollinate:** BA owns an ordered, hash-chained `ConsumptionChain` (`chain_id`/`commitment`/`previous`/`sequence`; `check_chain/2`). `ash_onetime` stays the **flat** `(scope, token)` reject-on-reuse ledger and does **not** implement the chain — the ordered chain is BA-protocol/BA-runtime territory (same discipline as not re-implementing provider schemes).
- **Open question (flag, don't decide):** the not-yet-built BA runtime (`bounded_authority`, B1) needs live consumption storage; whether it sits on `ash_onetime`'s ledger for the flat layer is B1's call.
- **Live convergence:** `navyler_cdc`'s report path hand-rolls EdDSA-sig + a nonce ledger today; its B2 upgrades the envelope to BA-protocol → *BA verifies → `ash_onetime` spends the `jti`*. navyler is the first real consumer of both.

## Historical status at capture time

Greenfield. **Design decided + recorded** (core-platform SD-15 + this repo's design note). **Idempotency reference impl characterized** (qorpay `Qorpay.Idempotency`). **Ecosystem gap confirmed** (no Ash-native idempotency lib on hex). **Build precedent captured** (`ash_age`). Repo is a scaffold — `docs/` (`handoffs/`, `superpowers/{specs,plans}`, `design-notes/`) + `.gitignore`; **not yet a git repo; zero source code.**

**Provenance:** the **idempotency** strategy is qorpay-backed. The **`:one_time_nonce`** strategy is a **2026-08-04 scope expansion** grounded in the design note + a real consumer (navyler's report path + `bounded_authority_protocol`) — no single reference impl the way idempotency has; lock its spec via `/brainstorm-autopilot` first.

## ⚠️ Worst open item first

**Greenfield — nothing built; the design is decided.** No blocking gate. The only pre-code step is a 2-minute duplicate re-check (largely done): no idempotency/nonce Ash extension on hex (`idempotency_plug` is Plug-only/pre-1.0), nothing official in-flight in `ash-project`. Then build.

- **Org = `github.com/baselabs`** (matches `ash_age`). Repo: **`baselabs/ash_onetime`**. You own it (MIT, your namespace) — no Ash-team gate.
- First action: `git init` + scaffold `mix.exs` mirroring `ash_age`.

## Done (verified — design/research artifacts, no code)

- **SD-15 recorded** — `core-platform/docs/specs/2026-06-30-core-platform-tech-stack-decisions.md` (`### SD-15`).
- **Design note** — `docs/design-notes/2026-08-03-scope-idempotency-vs-antireplay.md` (this repo): the one-lib decision, the idempotency-vs-anti-replay boundary, the signature line, the five signed-capability requirements, the `bounded_authority_protocol` cross-pollination + consumption-chain boundary.
- **Idempotency reference read** — qorpay `lib/qorpay/idempotency/`: `key.ex`, `store.ex` (dual-store PG-authoritative + Redis read-through, circuit-breakered), `expiration_worker.ex` (Oban TTL purge), `enforce_idempotency.ex` (Ash `change`); content-hash design in qorpay ADR-0022.
- **Gap confirmed** — no Ash-native lib on hex; `idempotency_plug` (MIT, pre-1.0) is HTTP-Plug-only, not Ash-aware.
- **Build precedent** — `ash_age`: Spark-DSL extension, MIT, full OSS hygiene, consumer-declared multitenancy (the parameterization precedent).

## Open / not done (the whole build)

Everything below is unbuilt. Ordered.

1. **Scaffold** — `git init` under `baselabs/ash_onetime`; `mix.exs` mirroring `ash_age` (MIT, `{:ash, "~> 3.x"}`, `{:spark, ...}`, ex_doc, hex `package` with `description`/keywords carrying idempotency + nonce + anti-replay), README/CHANGELOG/CONTRIBUTING/LICENSE/usage-rules.md/AGENTS.md. Name `ash_onetime` / `AshOnetime` (no version suffix — HARD rule).
2. **Lock the spec** — `/brainstorm-autopilot`: the DSL surface incl. the required `strategy`, natural-key + client-key + external-token key sources, the built-in `:hmac`/`:ed25519` signer + the verify seam contract, the (max_age, skew) window, the store contract, scope declaration.
3. **Core (parameterized — do NOT lift qorpay code):**
   - **Required `strategy`** `:idempotency | :one_time_nonce`, no default; `:one_time_nonce` carries no stored-response surface.
   - **Wiring** = an Ash `change` / Spark DSL section (Ash-action-native, transactional with the action — the differentiator vs `idempotency_plug`).
   - **`:idempotency`** = `processing → complete` (Stripe recovery-point); `insert_processing` (unique on `(scope, key)`) → execute → `complete(body, status)`; replay `find` returns the stored response. Key = `(scope-attrs, resource, action, client Idempotency-Key OR natural-key attrs)` + content hash (same key + different params ⇒ error). **Natural-key scoping is first-class, not header-only.**
   - **`:one_time_nonce`** = mint-or-accept token → (verify via seam) → **reserve-before-effect in the action's transaction** → spend; reject on reuse; (max_age, skew) window; eviction horizon = `max_age + skew`. Fail **CLOSED** on store error.
   - **Store** = PostgreSQL authoritative (via AshPostgres; the ledger row + the guarded action's DB write share one transaction) **+ optional cache adapter** (read-through, circuit-breakered — never a correctness dependency).
   - **TTL + eviction** = `expires_at` + an Oban purge worker; time-partition at scale (drop partitions vs DELETE).
   - **Optional Plug** — lifts `Idempotency-Key` / nonce / timestamp / signature headers into action context.
4. **Parameterization (the real library work — the `ash_age` lesson):** consumer **declares the scope attributes** (explicit, no global default; verified at compile time — see `ash_age/lib/multitenancy.ex` + `.../verifiers/validate_multitenancy_attr.ex`). Cache = optional adapter behaviour (`AshOnetime.Cache`, Valkey/Redis impl + a no-op default); do NOT hard-depend on a Redis client. Signer + verify seam are behaviours; the built-in `:hmac`/`:ed25519` are the shipped defaults.
5. **Scope discipline** — ship the single-use-keyed core (both strategies) + key/state-machine + PG store + stored-response replay (idempotency) + nonce lifecycle (mint + window + built-in signer + verify seam) + TTL/eviction + DSL/change + content-hash **+** optional cache adapter **+** optional Plug. **Resist over-scoping:** no built-in tenancy model, no bundled cache client, **no re-implementation of provider signature schemes** (seam → `ash_webhook_it`), **no consumption-chain** (that's `bounded_authority_protocol`). The line: one self-owned signing scheme in, the provider zoo and the ordered chain out.
6. **Tests (adversarial, contention/failure-first):** concurrent double-spend → exactly one winner + one rejection (real-transaction, two committed connections); idempotent retry returns the stored response; **nonce replay rejected**; store-error injection → nonce rejects / idempotency re-executes; **window transient-boundary** (token at `eval − max_age − skew` still rejected, past it evicted); content-hash mismatch errors; TTL expiry + reuse-after-expiry; crash-between-effect-and-complete recovery; cache-down degrades to Postgres (breaker open); **forged signature rejected with a byte-level tamper**; **out-of-window/expired timestamp rejected**; cross-scope token neither satisfies nor blocks another scope; wrong-strategy misuse unreachable.
7. **Docs + hex publish** — moduledoc-as-setup-guide (like `AshAge.ex`), usage-rules.md naming **both** misuses with equal weight (the collision — idempotency's stored response served to a replay; AND the failure — a nonce inheriting idempotency's fail-open on store uncertainty), `documentation/tutorials` + `documentation/dsls`, CHANGELOG. Publish to hex as `baselabs/ash_onetime`.
8. **Wire back into core_os** — once published, core_os imports it (satisfies SD-15); reflect the version pin when core_os seeds.

## Ash-extension conventions (follow `ash_rate_limiter` — the closest analogue)

`ash_rate_limiter` (ash-project) protects Ash actions with an action-level concern — same shape. Copy it:

- **Spark DSL extension:** `AshOnetime` (entry) · `AshOnetime.Resource` (`Spark.Dsl.Extension`) · `.Info` (introspection) · `.Transformers.*`/`.Verifiers.*` · `.Change`/`.Preparation` (action-level) · `.Store`+`.Store.Ecto` · `.Signer` (`:hmac`/`:ed25519`) + `.Verify` (seam behaviour).
- **Declarative DSL block**, `strategy` required — idempotency: `onetime do strategy :idempotency; key [:tenant_id, :idempotency_key]; ttl :timer.hours(24); replay [:status, :result] end`; one-time nonce: `onetime do strategy :one_time_nonce; scope [:tenant_id]; window max_age: :timer.minutes(5), skew: :timer.seconds(30); signer :ed25519 end`. Usage `use Ash.Resource, extensions: [AshOnetime.Resource]`; action-level escape hatch `change {AshOnetime.Change, …}`.
- **Igniter installer** `mix igniter.install ash_onetime`; **formatter** `:ash_onetime` in `import_deps`; **usage-rules.md** (LLMs hallucinate Ash internals) with `extensions:` + DSL-block + action-change examples; **docs** `getting-started-with-ash-onetime.md` + `DSL-AshOnetime.md`.
- Official guide: ash `documentation/topics/advanced/writing-extensions.md`; DSL tooling = **Spark**.

## Git + environment

- **`ash_onetime`** — not yet a git repo (`.gitignore` + `docs/` scaffold; renamed `ash_idempotency`→`ash_once`→`ash_onetime_it`→`ash_onetime`). First build step includes `git init`.
- **`core-platform`** — NOT a git repo (docs deliverable); SD-15 lives there.
- **`qorpay`** (`/Users/rp/Developer/Qor/qorpay`) + **`ash_age`** (`/Users/rp/Developer/Base/ash_age`) + **`bounded_authority_protocol`** (`/Users/rp/Developer/BaseLabs/bounded_authority_protocol`) are **READ-ONLY references** — do not edit them from this work.
- **No concurrent executor** on `ash_onetime`. No secrets (design/build only).

## Cadence + guardrails for the next agent

- **Anti-gravity (critical):** qorpay + ash_age are **reference-only** — extract the *shape/lessons*, do not lift code (qorpay's version is entangled with its `ScopeAxis` tenancy + Redis). `bounded_authority_protocol` is a **consumer + boundary** reference — read its verify API + consumption-chain to draw the line, do not depend on or fork it.
- **Naming philosophy:** avoid the canonical `ash_idempotency`; keep `ash_onetime`. No version suffix in any file/module/identifier (ISO dates + `0001-` ADRs fine; never `_v1`/`_v2`). Version lives in `mix.exs`/git tags/CHANGELOG.
- **Mirror `ash_age`:** Spark DSL (`info`/`transformers`/`verifiers`), module-dependency-levels discipline, MIT, full OSS hygiene, `docs/superpowers/{specs,plans}` lifecycle.
- **Solo-project git:** commit directly to `main`; no feature branches/worktrees unless asked.
- **Honesty:** no "should work" — run the gates, cite the output. "Done" only with evidence.

## Referenced artifacts (by path — do NOT duplicate)

- **Design (authoritative reasoning):** `docs/design-notes/2026-08-03-scope-idempotency-vs-antireplay.md` (this repo) — read before the spec.
- **Design (decision record):** `core-platform` SD-15 — `/Users/rp/Developer/Base/core-platform/docs/specs/2026-06-30-core-platform-tech-stack-decisions.md`.
- **HARD RULE #1** (Stripe `Idempotency-Key` header, no version in paths/names): `core-platform/docs/adr/0001-api-surface-versioning.md`.
- **Idempotency reference impl:** `/Users/rp/Developer/Qor/qorpay/lib/qorpay/idempotency/` (+ qorpay ADR-0022 content-hash).
- **Build precedent:** `/Users/rp/Developer/Base/ash_age` — `lib/ash_age.ex`, `AGENTS.md`, `mix.exs`, `lib/multitenancy.ex` + `.../verifiers/validate_multitenancy_attr.ex`, `usage-rules.md`.
- **Signed-capability consumer + boundary:** `/Users/rp/Developer/BaseLabs/bounded_authority_protocol` (v0.1.0) — stateless RFC 9449 verifier (`verify_grant/3`, `check_envelope/2`); proof carries the spend key (`jti`) + window (`iat`/`exp`); owns the ordered `ConsumptionChain` that stays out of `ash_onetime`.
- **Signature-verification neighbour (verify-seam target):** `/Users/rp/Developer/Base/ash_webhook_it` — owns provider-signature schemes; `ash_onetime` delegates, never duplicates.
- **External canonical patterns:** Stripe idempotency (Idempotency-Key, 24h retention, params fingerprint, recovery points); RFC 9449 DPoP (holder proof, `jti`/`iat`, request binding) for the nonce side.

## Historical suggestions at capture time

1. **First:** `git init` + scaffold `mix.exs` (mirror `ash_age`), repo `baselabs/ash_onetime`.
2. **`/brainstorm-autopilot`** → lock the extension spec (per Open item 2) → `docs/superpowers/specs/`.
3. **`/plan-autopilot <spec>`** → executor-ready plan → `docs/superpowers/plans/`.
4. **`/exec-autopilot <plan>`** → build task-by-task with gates.
5. **`/review-autopilot`** before hex publish.

Concrete first step: `git init` + scaffold `mix.exs` mirroring `ash_age`, then `/brainstorm-autopilot` with the design note as the primary input.
