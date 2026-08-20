# 8. Token wire-format compatibility (window-bounded)

Date: 2026-08-19

## Status

Accepted. Companion to [7. Persisted response-format compatibility]
(0007-persisted-response-format-compatibility.md), which governs stored response payloads;
this record governs the canonical token wire format — a different surface with a
different bound. Ruled by the package owner from the option set (permanent freeze /
window-bounded / none) on 2026-08-19.

## Context

One-time-nonce tokens are self-identifying on the wire: the `ash_onetime.`-prefixed
canonical envelope binds the algorithm, key identifier, namespace, keyed-effect key, and
issuance/expiry instants (`AshOnetime.Token`). Unlike response payloads (bounded by
retention windows that can span months — ADR-0007), a token persists across releases only
for as long as its acceptance window: `max_age` plus `clock_skew`, typically minutes to
hours. A release that breaks verification of an in-flight token form strands those proofs
at the upgrade boundary — fail-closed (an unknown form or key identifier rejects; key
rotation already exercises that path), so never a security hole, but an availability
event for clients holding valid proofs through a deploy.

## Decision

**Window-bounded compatibility — no permanent freeze.** Within the 1.x line:

- A reader verifies tokens minted by any earlier 1.x writer **while those tokens remain
  inside their acceptance window** (`max_age` + `clock_skew`). The obligation expires
  naturally with each token's own window; nothing is frozen forever.
- Format evolution is **additive through the self-identifying envelope**: a new algorithm
  or envelope variant is a new self-identifying form; the previous form keeps verifying
  until windows drain. A representation change under an existing form identifier is a
  compatibility break.
- A breaking change requires either waiting out the longest configured acceptance window
  (named in that release's upgrade notes) or shipping verification for both forms through
  the transition.

Key rotation is the operational break-right and is NOT a compatibility concern: an
unknown `key_id` rejecting is the documented security posture (never fall back silently),
independent of format evolution.

## Alternatives considered

- **Permanent freeze (ADR-0007-style, old forms verified forever)** — rejected: token
  windows are minutes-to-hours, not retention months; permanent obligations would force
  improper engineering for a surface that self-expires.
- **No compatibility declaration (format freely breakable)** — rejected: safe (fails
  closed) but every breaking release would strand in-flight proofs — an avoidable
  availability tax, when the bounded obligation is nearly free.

## Consequences

- The token envelope joins the 1.0 frozen surface with a TTL-bounded scope: the cost of
  the obligation is at most one acceptance window per format change.
- Any release touching the token envelope states the window-drain requirement in its
  upgrade notes.
- Custom signer/verifier implementations inherit the same rule for the forms they
  produce; `AshOnetime.Token`'s documentation carries the contract.
