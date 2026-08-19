# 7. Persisted response-format compatibility (1.x cross-version surface)

Date: 2026-08-19

## Status

Accepted. Extends the 1.0 frozen-surface list (D1, #2) with the persisted response format
explicitly. This record must land before the 1.0.0 tag — it names a constraint the freeze
implies (D5, #6).

## Context

A completed idempotency claim persists everything needed to replay its response: the
payload row (`encoded_response bytea`, ceiling-checked), the claim's `response_codec` tag
(text, 1..128 bytes), `response_digest` (bytea, exactly 32 bytes), and the
`response_partition` binding. The digest is SHA-256, computed at write time and verified
with a constant-time comparison at replay; replay also gates on the stored tag equaling
the resource's configured codec's `format_tag/0` and on the stored digest matching the
runtime contract binding.

Retention outlives releases. Monthly partitions roll up to 18 forward months and
`retain_until` horizons can span many of them, so a payload written by a 1.0 writer must
decode and replay-verify under any later 1.x reader — a compatibility obligation the
codec-callback design implies but that was recorded nowhere. The unified hard-limit
vocabulary already has a named single source (`Codec.hard_limits/0` for the response
half, `Codec.protect_only_ceilings/0` for the protect-only half); what was missing is the
cross-version rule for the bytes and tags those limits govern.

## Decision

Persisted payloads — codec `format_tag` + digest algorithm + encoded bytes — are a
**forward/backward compatibility surface for the whole 1.x line**:

1. **Old format tags keep decoding forever within 1.x.** A codec configured on a resource
   must keep decoding payloads stored under its own `format_tag` across every 1.x release.
   Replay gates on tag equality with the configured codec, so dropping decode support for
   a previously-written tag breaks in-retention replays by construction.
2. **New codecs are additive.** Introducing a codec with a new `format_tag` never affects
   stored payloads. Changing a codec's encoded representation requires a **new tag** — the
   old tag keeps the old decoder semantics; a silent format change under an existing tag
   is a compatibility break. (Tags are constrained to `[A-Za-z0-9._-]{1..81}`, so the
   vocabulary is unbounded and collision-free.)
3. **Digest-algorithm changes only at 2.0.** SHA-256 / 32 bytes is frozen for 1.x — the
   install migration's `CHECK (octet_length(response_digest) = 32)` enforces the length,
   and replay's constant-time verify pins the algorithm. A 2.0 may change it with a
   migration-path story; nothing in 1.x may.
4. **`Codec.hard_limits/0` is the single limit vocabulary, and tightening a default is a
   behavior change.** Replay re-checks the stored payload's byte size against the
   *current* limits (`Codec.max_bytes/1`), so lowering `max_response_bytes` — at the
   package default or on a resource's declared limits — retro-rejects replay of larger
   payloads still inside their retention window. Any tightening therefore requires a
   release-notes callout naming the replay impact; loosening is additive.

## Consequences

- The persisted format joins D1's frozen surface: a 1.x release that breaks any rule above
  is a contract break, not a refactor.
- Custom consumer codecs inherit the same obligations (their `decode/4` must remain
  backward-compatible with their own prior `encode/3` output); this ADR is the reference
  the codec documentation points at.
- Limits stay sourced only from `Codec` — a new limit key added anywhere else cannot
  participate in the typo-discrimination set and would fork the vocabulary.

## Alternatives considered

- **Version the payload bytes with an internal schema number instead of the codec tag** —
  rejected: the tag already is the format identifier, it is human-readable in the claim
  row, and a second numbering scheme would duplicate it.
- **Treat persistence as ephemeral (retention is short; compat unnecessary)** — rejected:
  18-month forward windows plus `retain_until` horizons routinely outlive many releases;
  "usually fine" is not a compatibility posture.
- **Freeze the codec callback itself** — unnecessary: the callback contract
  (`format_tag/0`, `encode/3`, `decode/4`) can evolve additively; it is the *stored bytes
  under a tag* that are frozen, and rule 2 is the mechanism that keeps them so.
