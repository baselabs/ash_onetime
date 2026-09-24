# 9. Reap-surviving derived operation key

Date: 2026-09-24

## Status

Rejected.

## Context

Reaping an abandoned external-effect `processing` claim deletes the operation key with it
(the key is the claim row's UUID), so a post-reap retry executes at the peer under a new
key and no key-based defense remains at either layer ([2](0002-abandoned-processing-reaper.md)
amendment; the external-effects guide). A key derivation that survives reap — stable across
the logical key — was proposed as a mechanical close for that window.

## Decision

Rejected. Every reap-surviving scheme fails one of two ways:

1. **Stateless derivation** (`uuid5` of the logical key components, all in hand at both
   call sites): a stateless key survives *retention cleanup* exactly as it survives reap.
   A post-retention retry — which today is a documented new execution whose prior
   execution is known complete — would present the same key, and a correct peer replays
   the prior generation's stored result. The requested effect never happens: a disclosed
   duplicate traded for an undisclosed no-op, voiding 0001's "reuse after retention is a
   new execution" in the quietest direction.
2. **Stateful derivation** (an epoch advancing on cleanup, or a reap tombstone): correct
   only while the stored state outlives the *peer's* key-store retention — a value the
   package cannot know and the peer does not publish. The reap abandonment floor is 24 h
   and operators size it far higher, so the peer must retain keys past the operator's
   abandonment horizon for the dedup to fire at all.

Independently: the operation key is published callback API — `t:AshOnetime.ExternalEffect.operation_key/0`
is documented as "the authoritative committed claim UUID," and every conforming adapter
joins peer records back to claims by that UUID. A derived key silently breaks that join
for the entire installed base.

The operator-side defense stays: business-level reconciliation before enabling the reaper
on external-effect actions (operations guide, external-effects guide).

Revisit triggers: a real consumer reports a post-reap duplicate under a
reconciliation-following deployment; or the claim ever gains a durable monotonic
generation on the logical key, which dissolves the stateless/stateful dilemma and re-opens
this decision in its correct shape.
