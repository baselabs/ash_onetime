# 4. Security-driven Ash floor (CVE-patched version pinning)

Date: 2026-08-09

## Status

Accepted. Supersedes the `>= 3.29.3` floor documented in the v0.1.x/v0.2.0 README and `mix.exs`
(not a prior ADR — the floor was an inline documented constraint, not an architecture decision).
Tightens the published dependency requirement from `>= 3.29.3 and < 4.0.0` to
`>= 3.31.1 and < 4.0.0`.

## Context

`ash_onetime` is a security library (idempotency + one-time-nonce admission, replay fencing,
signature verification). AGENTS.md binds it to fail-closed semantics and treats the dependency
floor as a security surface: the floor is set to the lowest Ash version with no known unpatched
advisory, not to the lowest version that happens to compile.

Three Ash CVEs accumulated across the v0.1.x/v0.2.0 development window, each narrowing the
safe floor:

- **EEF-CVE-2026-55736** (private action arguments settable by user input) — affects Ash
  3.29.0–3.29.2, fixed in 3.29.3. This is the reason the original floor was 3.29.3, not 3.29.0.
- **EEF-CVE-2026-70395** (predicate injection in `manage_relationship` belongs_to lookup
  disclosing secret lookup keys) — affects Ash `< 3.31.1`.
- **EEF-CVE-2026-69659** (memory exhaustion via unbounded deserialization of keyset pagination
  cursors in `Ash.Page.Keyset`) — affects Ash `< 3.31.1`.

The latter two were published in the security-advisory database during the v0.2.0 release
closeout. `mix hex.audit` — a required gate in AGENTS.md and `.github/workflows/ci.yml` —
surfaced them against the locked `ash 3.29.3`. CI's `hex.audit` step had passed on the prior
run (the advisories were not yet in the DB), so this is a newly-published advisory, not a
pre-existing failure; but any push with the 3.29.3 lock would now red-bar CI's `hex.audit`.

Both new advisories are patched in Ash 3.31.1 (published 2026-08-09).

## Decision

Set the published Ash requirement to `>= 3.31.1 and < 4.0.0`, bump the committed lock to
`ash 3.31.1`, and set the CI compatibility-matrix floor to `3.31.1` (dropping the `3.30.1`
intermediate cell, which is below the patched floor).

The matrix becomes `[3.31.1, latest]`: the patched floor and the floating newest Ash 3.x. The
`latest` cell continues to exercise forward drift (the mechanism that surfaced the Splode 0.3.2
census skew in the same release window).

## Consequences

- **Consumer break (breaking constraint tightening):** downstream consumers pinned to Ash
  3.29.3–3.31.0 must bump Ash to ≥ 3.31.1 to use this version of `ash_onetime`. This is
  intentional and security-driven; the alternative — leaving the floor below the patched
  version — would make `hex.audit` fail for every consumer and admit a vulnerable transitive
  dependency from a library whose purpose is security enforcement.
- **Versioning:** the tightening is a breaking change to the dependency contract. It lands in
  the next release (post-v0.2.0) with a CHANGELOG entry calling out the floor move and the
  three CVEs; consumers read the CHANGELOG before upgrading.
- **Matrix coverage narrows** from three cells `[3.29.3, 3.30.1, latest]` to two
  `[3.31.1, latest]`. This loses continuous coverage of the 3.30.x line, but 3.30.x is below
  the security floor and is not a supported target. The `latest` cell still floats forward.
- **Forward drift detection is preserved:** the `latest` cell + the `deps.unlock ash` /
  `deps.update ash` step still surface transitive drift (e.g. Splode minor bumps) on every run.

## Alternatives considered

- **Pin only the lock, leave the published requirement at `>= 3.29.3`:** rejected. The
  published requirement is what every consumer resolves against; leaving it below the patched
  version lets a consumer install `ash_onetime` alongside a vulnerable Ash, defeating the
  purpose. The lock pin only fixes the development/CI build, not the consumer's resolution.
- **Drop Ash as a hard dependency:** out of scope and architecturally wrong — `ash_onetime`
  is an Ash extension.
- **Wait for Ash 4.0 to raise the floor:** rejected. The advisories are live now; waiting
  leaves consumers exposed for the 3.x→4.0 window of unknown length.
