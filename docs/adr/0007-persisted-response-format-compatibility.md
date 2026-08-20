# 7. Persisted response-format compatibility (1.x cross-version surface)

Date: 2026-08-19

## Status

Accepted. Extends the 1.0 frozen-surface list (D1, #2) with the persisted response format
explicitly. This record must land before the 1.0.0 tag — it names a constraint the freeze
implies (D5, #6).

## Context

A completed idempotency claim persists everything needed to replay its response, and each
piece is verified at replay against the **runtime contract**, not just the stored bytes:

- the payload row (`encoded_response bytea`, ceiling-checked);
- the claim's `response_digest` (bytea, exactly 32 bytes) — SHA-256 over the payload,
  compared with a constant-time equal;
- the claim's `response_codec` column — not a bare tag but a **binding**:
  `binding_prefix <> format_tag <> ":" <> base64url(contract_digest)` (the private
  `binding/2` in `Response`),
  where the contract digest is SHA-256 over a deterministic `term_to_binary` descriptor of
  the replay contract's facets: resource/action identity, kind, result mode, replay fields
  and their specs, type, constraints, allow_nil, the codec module, and codec options;
- the `response_partition` binding.

Replay (the point of trust for `:replay`) verifies all of them against the *current*
runtime contract: the claim shape, the payload byte size against the **current** limits
(`Codec.max_bytes/1`), the payload digest, the stored tag equaling the resource's
configured codec's `format_tag/0`, and the stored contract digest equaling the **current**
contract's digest.

Retention outlives releases. The install window spans the install month plus 12 forward
monthly partitions, `mix ash_onetime.gen.roll_forward` defaults to 13 months (universal
cap 24), and `retain_until` horizons are operator-declared with no library ceiling — a
payload written by a 1.0 writer must decode and replay-verify under any later 1.x reader
inside its retention window. That is a compatibility obligation the codec-callback design
implies but that was recorded nowhere. The unified hard-limit vocabulary already has a
named single source (`Codec.hard_limits/0` for the response half,
`Codec.protect_only_ceilings/0` for the protect-only half); what was missing is the
cross-version rule for the bytes, tags, and contract digests those limits govern.

Tag bounds live at two layers: the write path enforces `[A-Za-z0-9._-]` with a byte size
of 1..81 (`Codec.validate_tag/1` — an unbounded regex plus a separate size guard), while
the `response_codec` column's CHECK allows 1..128 bytes; the app-layer 1..81 governs what
can be written, the column bound is the storage-side slack.

## Decision

Persisted payloads — the codec `format_tag`, the contract-digest binding, the digest
algorithms, and the encoded bytes — are a **forward/backward compatibility surface for the
whole 1.x line**:

1. **A codec must keep decoding its own tag's bytes forever within 1.x.** The codec
   callback contract is `format_tag/0`, `encode/3`, `decode/4`; whatever byte
   representations a tag has produced, `decode/4` for that tag must keep accepting them
   across every 1.x release.
2. **The exact-tag gate is the design; a codec/tag switch is a breaking transition for
   that resource, not an additive upgrade.** Replay only decodes a stored payload when
   its tag equals the resource's currently configured codec's `format_tag/0` (and the
   stored contract digest equals the current contract's). This is deliberate: a payload
   must never be decoded by a codec or contract other than the one that wrote it —
   misinterpretation of bytes by a different codec is a replay-correctness hazard on a
   security surface, and the gate closes it. The consequence is that introducing a new
   codec or tag is additive only for **new writes**; repointing a resource whose
   in-retention payloads carry the old binding strands those replays
   (`:response_codec_mismatch` / `:response_contract_mismatch`) until retention drains
   them. A codec switch is therefore only safe after the old binding's retention window
   has emptied, and any switch guidance must say so.
3. **The binding syntax and the contract descriptor are frozen for 1.x.** The
   `prefix + tag + ":" + base64url(digest)` binding layout, the descriptor fact list that
   feeds the contract digest, and the deterministic-`term_to_binary` encoding are
   compatibility surfaces: changing any of them breaks replay of retained payloads by
   construction. Both digests are SHA-256/32 bytes — frozen until 2.0 (the install
   migration's `CHECK (octet_length(response_digest) = 32)` enforces the payload digest
   length); nothing in 1.x may change the algorithm.
4. **A resource's replay contract is frozen while its payloads persist.** Because replay
   compares the stored contract digest to the *current* contract's, any change to the
   descriptor facets — replay fields or their types/constraints, result mode, codec
   module, codec options — invalidates replay of that resource's in-retention payloads.
   Changing a replay contract is not free mid-retention; it is a transition that waits
   out the retention window (the same discipline as rule 2).
5. **`Codec.hard_limits/0` is the single limit vocabulary, and tightening a default is a
   behavior change.** Replay re-checks the stored payload's byte size against the
   *current* limits (`Codec.max_bytes/1`), so lowering `max_response_bytes` — at the
   package default or on a resource's declared limits — retro-rejects replay of larger
   payloads still inside their retention window. Any tightening requires a release-notes
   callout naming the replay impact; loosening is additive. Limit keys stay sourced only
   from `Codec` — a key added anywhere else cannot participate in the
   typo-discrimination set and would fork the vocabulary.

## Consequences

- The persisted format joins D1's frozen surface: a 1.x release that breaks any rule above
  is a contract break, not a refactor.
- Custom consumer codecs inherit the same obligations (backward-compatible `decode/4` for
  their own prior `encode/3` output; a tag switch waits out retention); this ADR is the
  reference the codec documentation points at.
- Upgrading docs for any release that touches codec, replay-contract, or limit surfaces
  must name the retention-window transition rule (rules 2, 4, 5).

## Alternatives considered

- **Version the payload bytes with an internal schema number instead of the codec tag** —
  rejected: the tag already is the format identifier, it is human-readable in the claim
  row, and a second numbering scheme would duplicate it.
- **Treat persistence as ephemeral (retention is short; compat unnecessary)** — rejected:
  12-month install windows, a 24-month cap, and unbounded operator-declared
  `retain_until` horizons routinely outlive many releases; "usually fine" is not a
  compatibility posture.
- **Permit multi-tag codecs (decode any tag the codec ever wrote) to make switches
  additive** — rejected: it re-opens the hazard the exact-tag gate closes (a payload
  decoded under a contract that did not write it) and hides the contract-digest binding,
  which would still fail the switch; the honest model is the transition discipline above.
