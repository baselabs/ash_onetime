# Security model

`ash_onetime` protects keyed effects against concurrent duplication and replay within an
explicit namespace. It does not authenticate a caller by itself, provide delivery, or turn
an unrecoverable external API into a transactional peer.

## Trust boundaries

- PostgreSQL is the sole admission authority. A cache cannot admit or reject work.
- Scope is mandatory. Missing tenant, attribute, argument, or resolver data is an error.
- Operation identity is derived from the resource and action; callers cannot supply it.
- Verification callbacks and minters return trusted local `AshOnetime.Verified` facts.
  Action input remains untrusted even when field names resemble trusted state.
- Stored responses are bound to locator hashes, request fingerprint, codec, SHA-256 digest,
  exact payload bytes, and declared Ash return shape before replay.
- One-time nonce store uncertainty fails closed. Only a proven never-dispatched idempotency
  checkout may use an explicitly enabled untracked path.
- External recovery treats every outcome except `{:ok, result}` and authoritative `:absent`
  as ambiguous and never retries the peer effect under a new decision.

Canonical encoding is bounded, type-tagged, length-framed, and deterministic. Token
verification binds exact canonical body bytes, expected namespace, algorithm, key identifier,
issuance, and expiry. HMAC-SHA256 requires same-service trust: anyone holding its verification secret also holds
signing power. HMAC verification happens at the holder with constant-time comparison.
Ed25519 separates private signers from public verifiers and uses pure RFC 8032 Ed25519,
not Ed25519ctx or Ed25519ph. Both algorithms operate over exactly the canonical body bytes.

`AshOnetime.KeyCustody` keeps signing and verification permission separate and binds each
key identifier to an authoritative algorithm and purpose. `KeyCustody.Local` fetches
purpose-specific, algorithm-tagged material and uses the package's reference signers;
external custody can keep secrets in another process or service. Custody is trusted
cryptographic code: the package checks exact signature lengths, normalizes failures and
bounds execution, but cannot detect a custody that falsely returns `:ok`. The conformance
suite checks known answers, cross-verification and rejection cases; it cannot prove a
constant-time comparison at an external holder. That is the implementer's obligation.
Secrets must remain in the consumer's secret store and must not be logged or committed.
See [Tokens and key custody](tokens.md).

## Named misuses

Misuse: using idempotency as replay defense. Idempotency returns a stored response on reuse;
it does not reject a captured signed request. Use `:one_time_nonce`.

Misuse: letting nonce admission inherit idempotency's optional untracked failure direction.
Nonce store failure and uncertainty must reject; there is no nonce fail-open configuration.

Misuse: using a shared HMAC secret across a separated signer/verifier boundary. Anyone who can
verify can then forge. Use Ed25519 or a verifier callback backed by the provider's supported
scheme.

Misuse: declaring `multitenancy strategy :attribute` without the tenant discriminator in scope.
Attribute-multitenant resources share one physical set of claim tables across every tenant, so
cross-tenant isolation rests entirely on the tenant being part of the scope; omit it and one
tenant is served another's stored response or burns another's nonce. `ash_onetime` rejects such
a resource at compile time — the scope must include `{:attribute, <tenant_attribute>}` or a
`{:tenant, module}` resolver. (Context multitenancy routes each tenant to its own schema and
needs no scope entry for isolation.)

Retention and cleanup are security boundaries. Deleting a nonce while its acceptance window is
still open can admit a replay. The acceptance window is evaluated on the application clock while
cleanup eligibility is evaluated on the PostgreSQL clock, so a spent nonce is retained for a
configurable clock-skew safety margin (`config :ash_onetime, :cleanup_clock_skew_margin_seconds`,
default 1 second) beyond its retention horizon (`retain_for`, defaulting to `max_age`, plus
`clock_skew`). Retention cannot be shorter than acceptance. Cleanup is therefore strictly later than the
acceptance window as long as the PostgreSQL clock is not ahead of the application clock by more
than that margin — keep both clocks synchronized (e.g. via NTP), and raise the margin for looser
synchronization. Processing external claims are retained for recovery until they are either
completed or reaped. An abandoned processing claim that never settles would otherwise be immortal
(cleanup skips it and the delete guard forbids deleting it), so a caller driving external-effect
actions with distinct keys and abandoning each after commit could accumulate unbounded undeletable
rows — a storage denial of service. The opt-in reaper (`mix ash_onetime.reap`) deletes such claims past a
separate, much longer abandonment horizon, through a sanctioned delete path: a processing claim is
removable only when it is older than both the operator's horizon and a hard 1-day floor and past
its own retention horizon, all re-enforced by the delete guard. Recoverability is thereby bounded
by `max(retention, abandonment horizon)` rather than unbounded. A retry after reaping runs
under a new peer operation key, so no key-based defense remains at either layer — enable
the reaper on external-effect actions only with a business-level reconciliation path (the
external-effects guide states the boundary). The reaper bounds steady-state growth, not a burst
(residual ≈ admission rate × that window); operators tune it with edge rate limiting and reap
cadence.
Telemetry is deliberately value-free to avoid exporting keys, tokens, signatures, payloads,
or verifier identities.

Report suspected vulnerabilities through the private process in [SECURITY](../SECURITY.md).

Completed idempotency claims may carry an operation hold. The caller must release a hold in
its settling transaction; an unreleased hold retains the claim and payload forever by design.
Use references unique within the installation's logical partition (a UUID is suitable).
References do not replace caller authorization or row-security policies: release touches only
rows visible to the caller's role. Monitor the held backlog and the live doctor for leaks.
The DELETE guard refuses held claims even for an owner or superuser, but does not stop
TRUNCATE, DROP, or a superuser's `session_replication_role = replica`. See
[Operation holds](idempotency.md#keep-an-open-operations-record) for the complete contract.


## Maintenance and the trusted server

Maintenance checks exact package relation shapes, including whole trigger rows, relation
flags, defaults, generated expressions, constraints, indexes, partition keys and bounds.
The shape omits only `pg_constraint.connoinherit` for PRIMARY KEY, UNIQUE and EXCLUDE
constraints (`contype IN ('p','u','x')`) on leaf partitions (`relkind = 'r'` and
`relispartition = true`). [PostgreSQL forbids inheritance from a partition](https://www.postgresql.org/docs/18/ddl-partitioning.html#DDL-PARTITIONING-DECLARATIVE-LIMITATIONS),
and the pinned relation kind and exact relation set exclude subpartitions, so that flag
cannot affect execution or enforcement there. This permits stock logical restores and
LIKE-created recovery children whose matching indexes ATTACH adopts. The flag remains
compared on roots, partitioned parents, non-partition relations, and every other constraint
type, including NOT NULL, CHECK and foreign keys.
Only the package policy may apply to the owner. Each step takes recursive SHARE UPDATE
EXCLUSIVE locks on every root before checking the catalogs and retains them through work
and its success record. Package routines require exact identity and a `prosrc` digest;
being built-in or owned by a superuser does not grant a routine blanket trust. Columns and
expressions must match the package's own DDL. Only the migration that just created the
package tables captures their shapes. Every upgrade builds a fresh DDL reference, even
if the old routines have been dropped. Unexpected shapes refuse maintenance with
`:untrusted_dependency`; status and the live doctor report the refusal.

The PostgreSQL server and the migrator are trusted. Superuser event triggers, preloaded
hooks, and backend libraries execute outside a relation closure. Autovacuum ANALYZE runs
as the table owner outside maintenance steps. The package cannot stop the server from
executing objects an owner or superuser installed. Install revokes runtime MAINTAIN and
steps audit effective MAINTAIN with `has_table_privilege`, including `pg_maintain`.
The audit also refuses SET-only paths from the runtime, maintenance or current role, or
any LOGIN role, to a role holding MAINTAIN on a package relation.
The CREATE and MAINTAIN audits exclude superusers (the trusted server) and roles that
inherit the owner's privileges (owner-equivalent). Runtime and maintenance roles must hold
no membership in the owner, whether through INHERIT or SET; every step checks that boundary.

Function DDL takes no relation lock. A migrator acting as the owner can replace a package
routine after its digest was checked. Relation locks cannot serialize that replacement;
the migrator must coordinate function changes with maintenance.


Package routines live in a dedicated schema owned by the table owner, with no public CREATE.
Every step audits effective CREATE with `has_schema_privilege`. Runtime retains CREATE only
in the table schema, so it cannot add a defaulted overload beside a package routine.
The EXECUTE ACL audit checks that dedicated routine schema. Only the owner and the
configured maintenance role may execute package routines, and the maintenance role must
not hold grant options. Same-named functions in the table schema do not enter this audit.
All package calls are schema-qualified and explicitly typed. The routine manifest checks the
whole executable `pg_proc` row, normalized argument-default and SQL-body trees, a zero
`prosupport`, and the source digest.
