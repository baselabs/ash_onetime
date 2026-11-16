# ADR 0007: Persisted response-format compatibility

Retained responses must replay across compatible 1.x releases. A codec must keep decoding
bytes produced under its own format tag. The binding syntax, deterministic contract descriptor,
SHA-256 digests, and encoded representations are compatibility surfaces.

Ash replay requires the stored codec tag and contract digest to equal the current resource's
binding; it also validates payload size, digest, claim shape, and response partition.
Changing codec/tag or contract facets while old payloads remain strands those replays.
Wait for their retention to drain before switching. Lowering current response-size limits can
also reject retained payloads and requires explicit upgrade guidance.

`AshOnetime.Transaction` is the raw-byte exception: the host supplies a bounded codec identifier
and exact response bytes. Replay checks that identifier, payload digest, and storage invariants;
it does not create the Ash response-contract binding or decode the bytes. Hosts own that format.
Response and protect-only limit vocabularies remain defined by `AshOnetime.Codec`.
