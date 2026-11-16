# ADR 0001: Single-use keyed effects

Every protected action declares `:idempotency` or `:one_time_nonce`, with no default.
Idempotency stores classified responses for replay; nonce protection rejects every reuse
and has no stored-response or external-effect surface.

Scope is explicit and nonempty. Missing data fails; it never becomes a global scope.
Operation identity derives from the protected resource and action. Attribute-multitenant
resources must include their tenant discriminator in scope; schema tenancy isolates by prefix.

PostgreSQL decides admission. Optional caches supply only validated response payloads.
Database admission commits with the protected resource's current transaction and repository.
External idempotency commits a processing recovery point independently before peer calls;
nonce `commit: :independent` commits a spend before the body (ADR 0003).

Only idempotency supports external effects. The package supplies the claim UUID as the peer
operation key. Execute must be idempotent; recover must prove a result, absence, or uncertainty.
The pre-peer claim lock serializes same-key calls (ADR 0010). Peer key deduplication remains
mandatory; callbacks run in the caller transaction and bound their own network calls.

Verification callbacks return trusted local facts. Input cannot assert verified state.
HMAC requires one signing/verifying trust domain; Ed25519 separates signer and verifier.
Provider-specific verification belongs in consumer callbacks, without adjacent-package dependencies.

Nonce store failure or uncertainty fails closed. Idempotency may execute untracked only by
explicit configuration when the store proves no admission statement was dispatched; telemetry
must expose that branch without values.

Claim cleanup enforces retention, including payloads in DEFAULT. Holds preserve completed
claims until released. Reap bounds abandoned processing claims (ADR 0002).
Prune reclaims only expired, empty monthly tables; roll creates forward months and relocates
DEFAULT payloads. Roll serializes with the two-integer transaction advisory key
`(1095717452, payload_parent_oid::integer)`, distinct from prune's key class.
Replay reads bind both claim ID and response partition. Write completion rejects duplicate
payloads across partitions; cleanup checks the claim's authoritative partition.
