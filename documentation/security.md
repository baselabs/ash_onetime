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
Historical upgrades do not widen that comparison. Before conversion, the installer checks
every root and child against same-server references built from package DDL, including the
primary keys left by the shipped logical-partition migration. It recreates only validated
historical CHECKs and primary keys, then requires the fresh shape. Names and physical
attribute positions were already excluded from shape identity; the conversion adds no
new excluded field. A missing or substituted constraint, extra index, changed default or
trigger, or independently altered child is refused before any recursive conversion.
Only the package policy may apply to the owner. Each step takes recursive SHARE UPDATE
EXCLUSIVE locks on every root before checking the catalogs and retains them through work
and its success record. Package routines require exact identity and a `prosrc` digest;
being built-in or owned by a superuser does not grant a routine blanket trust. Columns and
expressions must match the package's own DDL. Only the migration that just created the
package tables captures their shapes. Every upgrade builds a fresh DDL reference, even
if the old routines have been dropped. Unexpected shapes refuse maintenance with
`:untrusted_dependency`; maintenance status reports the refusal. The live doctor checks
schema currency, trigger firing modes, event-trigger ownership, runtime identity and held
backlog; it does not invoke the maintenance trust audit.

Containment starts with every package relation and partition, its indexes, constraints,
triggers and package policies, package routines and the routine schema. It follows every
outgoing dependency, every internal part, and every member of each reached extension until
no more objects are found. Both extension membership and `DEPENDS ON EXTENSION` reach the
extension. There is no OID cutoff: the language dependency reaches the unpinned `plpgsql`
extension, its handlers and their schemas. Every containing schema is checked, including
`public` and `pg_catalog`. An untrusted schema owner can remove objects it does not own
through `DROP SCHEMA ... CASCADE`.

Every reached owner must be the package owner, a superuser, or `pg_database_owner` when the
database owner is the package owner or a superuser. For each accepted owner other than the
package owner, every role with MEMBER reach to it must be a superuser or a member of the
package owner. This includes INHERIT-only, SET-only and ADMIN-only membership and the actual
database owner behind `pg_database_owner`. Refusals name the object, owner and offending
holder. `DROP DATABASE` is outside this containment boundary, like superuser actions.

Every database event trigger, enabled or disabled, is also checked: its function must have
an accepted owner and holders under these same rules. Trust and the live doctor name the
trigger, function and owner on refusal. DDL and login event-trigger functions execute under
the invoking identity, so an untrusted function owner could replace its body and borrow the
migrator's or maintenance role's authority.

The PostgreSQL server and the migrator are trusted. Trusted event triggers, preloaded
hooks, and backend libraries execute outside a relation closure. Extension install and update
scripts are server code that the server administrator installs. Depending on the control file
they run as the bootstrap superuser or as the installing role. Either way they are outside the
trust model, like superusers. Autovacuum ANALYZE runs
as the table owner outside maintenance steps. The package cannot stop the server from
executing objects an owner or superuser installed. Install revokes runtime MAINTAIN.
Install, maintenance steps and status use one effective-authority audit
over PostgreSQL roles. It refuses MAINTAIN on every package relation (including
`pg_maintain`), TRIGGER, TRUNCATE and REFERENCES on claims, nonce and payload roots,
and every table or column privilege on owner-only relations, including the maintenance
ledger and inheritance children. REFERENCES includes column grants. PostgreSQL's
`has_table_privilege` and `has_any_column_privilege` also detect `pg_read_all_data`
and `pg_write_all_data`, which do not need explicit relation ACL entries.
The same audit refuses SET or ALTER SYSTEM on `session_replication_role`, checked
with `has_parameter_privilege`, and membership in `pg_create_subscription` through
any membership edge. [Subscription apply workers run in replica mode](https://www.postgresql.org/docs/18/logical-replication-architecture.html),
which bypasses ORIGIN-enabled triggers. Package claims and nonce DELETE guards and every
fact append-only trigger use ENABLE ALWAYS, including partition clones. Trust refuses any
other firing mode. In replica mode only, a DELETE guard admits a writer able to SET to the
relation owner (including the owner and superusers), before deleting any payload; logical
apply mirrors the publisher's payload deletion itself. Every other writer gets the full
origin rules. Fact triggers always refuse mutation, including by a trusted replica writer. Any subscription
in the current database owned by an untrusted role is refused even after its creator's
`pg_create_subscription` membership has been revoked; disabled, disconnected subscriptions
count too.

Every non-predefined role holding forbidden authority is refused, even if NOLOGIN and
unreachable by any login: a holder-owned view or SECURITY DEFINER function granted to
PUBLIC can expose that authority. PostgreSQL reserves the `pg_` prefix for predefined
roles. Those roles count when reachable from runtime, scheduled maintenance, current or
session roles, or any LOGIN role, through any membership (`MEMBER`), including ADMIN
without INHERIT or SET. ADMIN-only members can grant themselves SET. Superusers (the
trusted server), the owner, and roles with USAGE or SET on the owner are excluded from
both holder and subject checks, including the subscription-owner check. The CREATE audit
excludes superusers and roles that inherit the owner's privileges. Runtime and maintenance
roles must hold no membership in the owner; every step checks that boundary. Run the live
doctor once for each runtime role; it refuses the owner or any role with MEMBER or ADMIN
authority on the package owner, naming the role.

SELECT on owner-only relations remains a trust refusal, including `pg_read_all_data`.
Forward roll copies the payload root's policies and RLS flags to newly created children.
The install loop adds the maintenance policy to existing children, but does not copy all
root policies or RLS flags, and relation shapes do not pin either to the root. A read-only
grant therefore cannot safely be left to the explicit ACL status check alone. Scope backup
grants to the package parents and other required application relations; revoke broad read
membership or grants on package children and the ledger before maintenance can proceed.

Maintenance first ships in 2.0.0. Fresh installs and maintenance upgrades from previously
shipped releases embed these routine bodies and pin their digests in the install manifest.
A package update alone never rewrites database routines. Function changes must rebuild
both manifests together; replacing a body alone leaves its recorded digest stale.

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
