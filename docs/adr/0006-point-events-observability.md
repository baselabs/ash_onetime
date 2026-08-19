# 6. Point-events observability (value-free telemetry posture)

Date: 2026-08-19

## Status

Accepted. Transcribes the telemetry contract decision (D3, #4) and the posture underneath
it into the repo's durable record; `documentation/telemetry.md` is the binding surface
contract (docs-are-contract, D1). Extends, does not supersede, any prior record.

## Context

`ash_onetime` is a security library: its telemetry stream observably carries admission
decisions for keyed effects, and the values flowing through those decisions — raw keys,
scopes, tokens, fingerprints, payloads, signatures, resolver identities, exceptions, store
results — are exactly the material the library exists to protect. Whatever shape the
telemetry surface takes, it must be impossible for that material to leak through it.

The ecosystem default for latency-bearing telemetry is the span triple
(`:telemetry.span/3` emitting `:start`/`:stop`/`:exception`). Two properties of `span/3`
disqualify it on this surface:

1. It force-injects `telemetry_span_context` onto every event's metadata unconditionally —
   a fifth metadata key by construction, breaking any closed metadata shape.
2. It emits `:exception` with `kind`/`reason`/`stacktrace` merged onto the metadata
   *inside* the span, before any caller `rescue` can catch it. An exception reason or
   stacktrace can carry secret-bearing terms — an `AshOnetime.Error` with request context,
   a `Postgrex.Error` with query text, a typed-argument mismatch carrying a token — and
   the span fires the event before the admission entry points' typed-error coercion runs.

Latency measurement does not require spans: the latency-bearing events already carry
`:duration` on the point event, which suffices for p99/SLO math.

## Decision

**Point events only, value-free metadata, two event classes.**

- **No span events.** Every event is a single `:telemetry.execute/3`. There is no
  `*.start`/`*.stop`/`*.exception` triple on any event family, and none may be added.
- **Value-free, atoms-only metadata.** The 12 admission/business events carry exactly
  `%{strategy, resource, action, result_class}`; the single diagnosis event
  (`[:ash_onetime, :uncertain_exception]`) carries `%{strategy, phase, exception}` with
  the exception **module** atom only — the class, never the struct. Measurements are only
  `:duration` or `:count`. The shapes are validated by the telemetry module before
  emission and pinned by the `forbidden-telemetry` mutation fixture; low cardinality is a
  by-product (atoms only), so a high-cardinality label can never leak either.
- **The default router covers the full closed surface.** `AshOnetime.Telemetry.attach/0`
  is a pure router re-emitting all 13 events as `[:ash_onetime, event, :metric]` with
  unchanged metadata and a normalized measurement — no state, no silent drops (the
  diagnosis event rides the same attach point), no `telemetry_metrics` dependency. A
  consumer reaches standard dashboards by attaching their own `Telemetry.Metrics`
  reporter to the `:metric` stream; a central reporter can declare definitions against
  the original events instead.
- **Trace correlation happens at the consumer boundary.** A consumer needing
  start/stop pairing for distributed tracing wraps their own call site in
  `:telemetry.span/3`, where they own the metadata and the exception handling — the
  library's point events remain the authoritative classified record.

**Rejected alternatives.** *Spans at the library boundary* — the leakage vectors above are
by construction, not convention. *A `metrics/0` helper returning `Telemetry.Metrics`
definitions* — requires `telemetry_metrics` as a hard dependency (against the standalone
boundary for a convenience) or optional-dep conditional compilation (seam complexity for
three lines of consumer code); can be added additively post-1.0 if demanded.
*Value-bearing metadata behind an opt-in* — an opt-in leak is still a leak; the surface's
value is that it cannot be misconfigured into one.

## Consequences

- The telemetry surface is closed and small: 13 events, fixed metadata shapes, two
  measurements. `documentation/telemetry.md` is the contract; drift between it and the
  emitters is a contract defect, not a docs nit.
- Handlers attach by event name and branch on `result_class` — an atom that is always
  present on the 12 admission events; the diagnosis event carries
  `%{strategy, phase, exception}` instead, and its handlers branch on `phase` and the
  exception module. A handler indexing into value-bearing fields gets `nil` by design.
- Operational alerting (admission failures, store uncertainty, outcome-unknown recovery,
  untracked executions) is fully served by point events; nothing observable is lost by
  the absence of spans.
