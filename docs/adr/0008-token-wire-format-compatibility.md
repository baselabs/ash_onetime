# ADR 0008: Token wire-format compatibility

Within 1.x, readers must verify earlier writers' tokens throughout their acceptance windows
(`max_age` plus `clock_skew`). The obligation expires when those windows drain.
New algorithms or envelope variants use a new self-identifying form; changing bytes under an
existing identifier breaks compatibility. Keep verification for both forms through transition
or wait out the longest configured acceptance window before switching.

Unknown forms and unknown key identifiers fail closed. Revoking a key intentionally invalidates
its proofs and remains independent of format compatibility.
