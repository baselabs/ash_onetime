# ADR 0014: Durable external claims and per-attempt outcomes

Accepted. Amends ADR 0002 and ADR 0010. ADR 0009 remains rejected.

Effect locality is fixed at insertion. The claim carries its granted attempt; an independent
append-only relation carries outcomes keyed by claim and attempt. Only local processing
claims reap. External and historical unknown processing claims survive every maintenance
path and prevent an ordered rollback from removing their protection.

Each external dispatch grants an attempt in a committed worker, classifies that attempt
under the caller lock, calls the peer with the original UUID, and either completes at that
attempt or records held/absent_proven in an independent committed worker. No outcome means
unresolved. An older outcome never describes the current attempt. Completion binds the
attempt and rolls back its payload if the attempt no longer matches.

The insert bound is an invoker trigger and refuses an attempt the claim has not granted.
The outcome guard runs as the package owner with row_security=off. It refuses all updates
and deletion while the parent exists; its plain parent read sees all rows or raises. The FK
cascade preserves PostgreSQL's SECURITY_NOFORCE_RLS context, so cleanup can remove a claim
and its outcomes under FORCE. Neither guard adds a claim row lock.

Outcomes copy the claims table's ENABLE/FORCE flags and carry only the maintenance and claim
visibility policies. The invoker visibility helper performs a plain claims read under the
reader's policies. Its exact, non-grantable owner/PUBLIC EXECUTE ACL is the routine exception.
Outcomes grant runtime SELECT/INSERT only. Trust audits effective forbidden table and column
authority, including inherited and predefined privileges.

The claim trigger fixes identity and locality, admits initial processing attempts, advances
attempts by one while processing, clamps both deadlines, derives response deadlines for old
writers, requires the one matching payload at completion, and permits response removal only
through eligible maintenance expiry. Direct completion and hold release remain trusted
application assertions. Response bytes can expire before the claim and fingerprint do.

Every package trigger is ENABLE ALWAYS. In replica mode the invoker triggers admit the owner,
a role able to SET ROLE to it, or a superuser; other writers meet their ordinary refusals.
Trusted mirrors of FORCE relations require BYPASSRLS on both the applying role and the
package owner. Full archive restores preserve firing modes. Data-only restores use a trusted
role in replica mode, with BYPASSRLS under FORCE. After any restore run the live doctor for
each runtime role and maintenance trust.

The following inventories are closed. A change introducing a statement, relation, privilege
or wait source updates its inventory and its executable proof or operational boundary in
the same change.

| Wait source | Package treatment |
|---|---|
| W1 relation locks | External DML is armed; maintenance pins 5s; upgrade/rollback ACCESS EXCLUSIVE is armed at 5s. |
| W2 tuple locks | The armed lock timeout bounds heavyweight row-lock queues. |
| W3 transactionid | The same bound covers row holders, unique checks and FK waits. |
| W4 spectoken | Reserve's speculative insertion inherits the worker bound. |
| W5 virtualxid | Concurrent migration indexes are outside runtime bounds; run with no long transactions. |
| W6 object | Function, schema and role DDL is coordinated by the migrator. |
| W7 extend, frozenid, page | Short internal server locks are outside package bounds. |
| W8 advisory | Roll is bounded at 5s; prune tries without waiting; fact boundary locks use separate tenant/tag keys. |
| W9 userlock, applytransaction | No package statement uses these. |
| W10 unique indexes | Reserve and outcome inserts use their worker lock timeouts. |
| W11 foreign keys | Outcome KEY SHARE and cleanup cascade are bounded by the executing statement. |
| W12 deferred constraints | Package constraints are immediate; trust refuses deferrability changes. |
| W13 triggers | Package triggers fire ALWAYS; trust refuses consumer triggers on package relations. |
| W14 policy functions | They inherit the statement bound; code changing timeout settings is outside it. |
| W15 serialization | SSI aborts; consumer safe-snapshot waits are outside package bounds. |
| W16 commit, I/O, LWLock, buffer pin, client | Non-lock server waits are outside the lock bound. |
| W17 local claims and hold release | Consumer lock_timeout and statement_timeout apply. |
| W18 event triggers, including login | Trust and the live doctor audit function owners and holders; called server code is trusted configuration. |

Policy functions can change timeouts through a function SET clause, set_config, SET or
SET LOCAL. A function clause lasts for its call. After a successful bounded statement, the
store's SET LOCAL restoration ends a transaction-local lock_timeout change and masks a
session-level one until transaction end. COMMIT preserves a session-level change; ROLLBACK
undoes it. The package does not restore statement_timeout. Changes govern later statements
without rearming an already running statement's timer. Callback SQL remains ambient.

| Authority source | Package treatment |
|---|---|
| A1 relation and column ACLs | Normalize new objects and audit explicit/PUBLIC and effective privileges. |
| A2 routine ACLs | Owner/maintainer only, except the exact PUBLIC visibility-helper grant. |
| A3 ownership and owner-equivalence | Trusted boundary; trust refuses owner-equivalent maintainers, and the live doctor refuses each runtime role that is owner-equivalent. |
| A4 role membership | Audit INHERIT, SET and ADMIN reach, including inactive holders. |
| A5 pg_read_all_data, pg_write_all_data, pg_maintain | Audit their effective package authority. |
| A6 monitoring, settings, statistics, checkpoint, reserved connections | These grant no package relation authority. |
| A7 backend/autovacuum signalling | Liveness boundary; interrupted attempts remain recoverable. |
| A8 server file/program roles | Superuser-equivalent boundary. |
| A9 default privileges | Normalize every new relation and child; audit later grants. |
| A10 parameter privileges | Refuse SET/ALTER SYSTEM on session_replication_role; ALWAYS guards still enforce writes. |
| A11 BYPASSRLS | Changes visibility, never DML privilege; structural safety does not depend on RLS. |
| A12 superuser | Trusted server boundary. |
| A13 CREATEROLE | PostgreSQL membership rules and effective-holder audits apply. |
| A14 schema CREATE/USAGE | Audit containment and routine-schema CREATE; fixed paths and OID bindings prevent shadowing. |
| A15 row-security widening | Pin maintenance and outcome visibility policies; refuse owner-widening consumer policies. |
| A16 logical replication | Refuse untrusted subscription authority/ownership and publication filters; ALWAYS guards refuse untrusted apply. |
| A17 security labels | Trusted server-module boundary. |
| A18 extension scripts | Administrator-installed server code is trusted; dependency ownership remains audited. |
| A19 containment and dependencies | Audit every dependency, internal part and extension member and its schema/owner/holders, with no OID cutoff. DROP DATABASE remains trusted administration. |
| A20 runtime writes | Enforce structure and monotone retention; completion truth, payload content and direct hold release are application assertions. |

For A19, accepted owners are the package owner, a superuser, and pg_database_owner when the
database owner is the package owner or a superuser. Holders of another accepted owner's
authority must themselves be superusers or members of the package owner. The dependency
closure follows referenced objects, internal components and extension members recursively.
The live doctor must run for every runtime role; the package keeps no runtime-role registry.

| Claim lock | Statement | Mode and bound |
|---|---|---|
| L1 | Reserve INSERT ON CONFLICT | Worker timeout, including speculative/unique waits. |
| L2 | Grant select and attempt increment | FOR UPDATE under worker timeout. |
| L3 | Caller pre-peer classification | FOR NO KEY UPDATE under the external bound. |
| L4a | Finalize reread | FOR NO KEY UPDATE under the external bound. |
| L4b | First replay load | FOR NO KEY UPDATE under the external bound. |
| L5 | Payload INSERT and claim completion UPDATE | Existing NO KEY UPDATE claim lock; both writes armed. |
| L6 | Local-path claim | FOR UPDATE with ambient bounds. |
| L7 | Hold release UPDATE | NO KEY UPDATE with ambient bounds. |
| L8 | Response expiry | FOR NO KEY UPDATE SKIP LOCKED. |
| L9 | Reap local claims | FOR UPDATE SKIP LOCKED, then DELETE. |
| L10 | Cleanup completed claims | FOR UPDATE SKIP LOCKED, then cascading DELETE. |
| L11 | Outcome INSERT FK check | FOR KEY SHARE; armed bound plus a 5s worker margin. |
| L12 | Historical v1.9.2 caller | FOR UPDATE under that runtime's bounds. |

All external caller locks and rereads use NO KEY UPDATE; grants retain UPDATE. Maintenance
takes SHARE UPDATE EXCLUSIVE on roots in a fixed order, including outcomes after claims.
These table locks permit runtime DML. Roll/prune ACCESS EXCLUSIVE affects payload relations.
Upgrade and ordered rollback lock claims/outcomes before exact refusal counts at 5s.

| Compatible pair | Concurrent work |
|---|---|
| P1 | L3 at n+1 and a late L11 at n. |
| P2 | L3 followed by L4a and a late L11. |
| P3 | Uncommitted completion L5 and L11. |
| P4 | Uncommitted L11 and L3. |
| P5 | Uncommitted L11 and L5. |
| P6 | Uncommitted L11 and L7. |
| P7 | Uncommitted L11 and expiry L8; expiry processes the claim rather than skipping it. |
| P8 | L3 holder, queued L2, and a third-session L11. |
| P9 | L11 at n and L11 at n+1. |
| P10 | Maintenance root locks and L1/L3/L5/L11. |
| P11 | L2 or L3 and an outcome visibility read. |
| P12 | L3 and L11 through a consumer policy taking KEY SHARE. |
| P13 | L3 on C1 and cleanup of C2 with its cascading outcomes. |
| P14 | Replay L4b and a late L11; the stored response still replays. |

These guarantees cover package statements. A consumer function can take stronger locks.

| Contending pair | Required result |
|---|---|
| B1 | L2 beside L3 reaches its armed bound and returns request_in_progress. |
| B2 | A second L3 reaches its armed bound. |
| B3 | L11 waits for L2's grant commit, then inserts. |
| B4 | L11 waits for cleanup: commit gives 23503/outcome_unrecorded; rollback permits insertion; timeout retains the claim. |
| B5 | Cleanup/reap skip an uncommitted L11; after commit an eligible claim is processed. |
| B6 | L11 beside historical L12 times out; the claim stays unresolved. |
| B7 | Expiry/reap/cleanup skip a caller-held candidate and process it after release if eligible. |
| B8 | Upgrade/rollback lock waits end at 5s; queued runtime work retains its own bound. |
| B9 | Stronger consumer policy locks end at the statement bound unless consumer code replaces it. |
| B10 | Reserve waits for an in-flight insert/delete of the same key, then proceeds or times out. |
| B11 | Completion payload contention ends at its armed bound; retry recovers the peer result under the original UUID. |
| U1 | Claim unique-index waits show transactionid contention and end at commit, rollback or the worker bound. |
| U2 | Outcome PK waits are bounded; a committed duplicate is a store invariant failure. |

Idempotency selection first locks only the claim, then always joins the claim, payload and
current outcome in a new statement without a lock clause. The second statement's claim
columns are authoritative. Both statements stay inside the armed timeout; nonce selection
keeps its single locking statement. READ COMMITTED gives the joined read a snapshot after
the claim lock is acquired, including outcomes committed while it waited. Ambient
REPEATABLE READ and SERIALIZABLE transactions remain rejected with unsupported_isolation.

An ambient transaction's earlier payload read, a queued maintenance ACCESS EXCLUSIVE lock
and another caller's claim lock can form a cycle through lock-queue order. PostgreSQL may
reorder waiters; otherwise the armed timeout returns request_in_progress. Neither path
changes a claim merely to break the cycle.

External recovery points have no maintenance deletion horizon. Their storage is deliberately
unbounded until recovery completes them; kept_external and doctor state expose the backlog.
Ordered rollback refuses unresolved external claims, and external-state rollback also refuses
expired responses. Running historical downs out of order is trusted owner DDL. Concurrent
index migration steps require a deployment window without old, long transactions.
