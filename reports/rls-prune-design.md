# RLS-safe payload-partition prune — design

Status: **accepted by b-1 review (November 9, 2026) with two changes; implemented red-first
(b-2 directive), all matrix cells green on ephemeral PostgreSQL 18 and the full suite green
on the shared instance, held for i-1 review before push. 1.9.0 unpublished.** Scout output
per `kimosabe-scout`; the judged recommendation survived an adversarial review and an
independent judge, and every load-bearing claim has executable evidence on a real
PostgreSQL 18.

Implementation notes (November 9): the store's prune is `owner_savepoint_prune/3` and its
helpers in `lib/ash_onetime/store/postgres.ex`; cleanup calls the existing
`transaction_preconditions/1` (F1) and returns `payload_partitions_kept` additively (F2);
relations are schema-qualified once (F3) and the OID re-check gates `relkind = 'r'` (F5);
the claims count is gone (F9). `copy_parent_row_security/3` keeps the ENABLE/FORCE and
policy copy and no longer grants any prune role (b-1 change 1). The `--rls-prune` generator
surface, template, and the never-shipped `:row_security_blocked` code are removed. Five
mutation rows pin the load-bearing lines (`scripts/check_mutations.exs`).

**b-1 changes to the scout's design:**

1. `copy_parent_row_security` keeps copying the parent's ENABLE/FORCE settings and full policy
   set onto new partitions; only the `ash_onetime_prune` SELECT grant is deleted (with the rest
   of the RLS-prune apparatus). Reason: the estate's two-login model gives the runtime role
   default privileges on tables the owner creates, so child partitions are directly queryable
   by name — without child-level policies that is a cross-tenant read (the class of leak i-1
   proved November 8). A red test pins it: a runtime role with default privileges reads a
   child partition directly and sees only its tenant.
2. The consumer pattern is owner-run maintenance on a schedule (schema owner, CronJob with the
   migrator Secret — the agent_access `Release.maintain_partitions` shape; its source is
   outside this session's open location, so the docs describe the pattern, not its internals).
   An in-app worker running as a non-owner sets `partition_limit: 0`. Kept companions: F1, F2,
   F3, F5, F8, F9.


## The question, and the invariant that answers it

How does cleanup decide a payload partition is safe to DROP, such that no consumer
configuration can make it drop a partition holding any tenant's rows — proven as an invariant,
not as a list of cases?

Three review rounds closed three policy shapes (restrictive TO public; restrictive TO the prune
role; restrictive via group membership — the last still open on `fec9b2e`). The root cause was
never any single shape: the prune counted as a non-owner role that RLS can narrow, and each fix
enumerated one more bad shape. The invariant that closes the class comes from PostgreSQL
itself, in `check_enable_rls` (`src/backend/utils/misc/rls.c`, REL_18_STABLE) — evaluated in
this order: built-in/RLS-off relation → `RLS_NONE`; **BYPASSRLS** role → `RLS_NONE_ENV`;
**table owner on a non-FORCE table** → `RLS_NONE_ENV`; `row_security = off` → error; else
policies apply silently. An owner counting a table it just un-FORCEd, with `row_security` off,
is therefore in one of exactly two states: the count is unfiltered, or the statement errors.
Nothing about policy shape, role membership, grants-by-name, or catalog contents can produce a
third state. That is the invariant.

## Recommended design: B2-owner — the owner-savepoint prune

Cleanup already has to run as the table owner under RLS, because only the owner can DROP. So
the owner uses its own exemption, scoped to a subtransaction that no other session can observe:

Per past-retention partition, inside the cleanup transaction:

1. `SAVEPOINT`.
2. `LOCK TABLE <partition> IN ACCESS EXCLUSIVE MODE` — the DROP's own lock, taken up front;
   concurrent writers are serialized behind it (probe: an in-flight parent-routed insert
   commits, the lock waits it out, the fresh count sees the row, the partition is kept).
3. Re-verify by OID: the relation is a plain heap (`relkind = 'r'`), is a child of this
   schema's payload parent, and is owned by `current_user`.
4. `ALTER TABLE <partition> NO FORCE ROW LEVEL SECURITY` — uncommitted, invisible to every
   other session (the lock guarantees no concurrent reader).
5. `SET LOCAL row_security = off` and count the partition. Owner + unforced ⇒ exempt before
   the `row_security` check; the count is unfiltered or errors. The GUC is belt, not load.
6. Empty ⇒ `DROP TABLE`, `RELEASE SAVEPOINT`; otherwise (or on any error) `ROLLBACK TO
   SAVEPOINT` — which restores FORCE — record the partition as kept with a reason, and let the
   cleanup loop continue.

Claims-count: deleted from the decision (F9, both reviewers): a completed claim and its
payload commit 1:1 on library paths, so the payload count subsumes it, and the claims count
only added a second RLS-narrowable surface (it was the sole reason the old B2 lost cell 08).

### Why this is not "one more case list"

The safety property is a two-state mechanism: **owner-of-unforced-relation + row_security=off
⇒ unfiltered-or-error**. It names no policies, no roles, no membership shapes, no catalogs.
Every RLS configuration a consumer can build resolves into one of the two states before any
policy is consulted. The only enumerated thing left is physical (`relkind`, inheritance,
ownership) — a closed set the database itself maintains, checked by OID inside the same
subtransaction as the count.

## Probe evidence (ephemeral PostgreSQL 18.6, non-superuser CREATEROLE owner, FORCE RLS)

Full runs: `.kimosabe/research/{rls-prune-pg18.md, rls-prune-matrix-note.md, matrix.tsv,
results.log, b2o_matrix.tsv, b2o_results.log}`. Harness defects found during the runs (three,
all mine, all fixed and re-run) are recorded in the matrix note.

### B2-owner matrix (runner = the owner-savepoint sequence above)

| Cell | Safety (partition holding tenant-b's row) | Capability (empty partition) | FORCE restored |
|---|---|---|---|
| 01 RLS off | KEPT | DROP | n/a (never forced) |
| 02 benign FORCE + tenant policy TO app role | KEPT | DROP | yes |
| 03 RESTRICTIVE TO public on child | KEPT | DROP | yes |
| 04 RESTRICTIVE TO ash_onetime_prune | KEPT | DROP | yes |
| 05 RESTRICTIVE TO group ∋ prune role (i-1 case C) | KEPT | DROP | yes |
| 06 child RLS on, no permissive policy (default deny) | KEPT | DROP | yes |
| 09 RESTRICTIVE TO public on claims | KEPT | DROP | yes |
| 12 caller arms row_security=off | KEPT | DROP | yes |
| 14 used-then-emptied (pages allocated) | KEPT | DROP | yes |
| 15 sub-partitioned child (relkind `p`, row in a leaf) | KEPT (relkind gate) | DROP (its plain sibling) | yes |
| 17 event trigger blocking ALTER TABLE | KEPT (fails closed) | DROP | yes |
| 18 non-owner driver (`app_r`) | KEPT (`permission denied`, fails closed) | KEPT (same) | yes |
| 16 REPEATABLE READ session | KEPT (refused by isolation precondition) | not attempted | yes |

Concurrency probes: parent-routed insert in flight ⇒ lock waits, count sees both rows, kept;
insert arriving during the prune window ⇒ blocked, then routed to `_default` (or errored where
no default exists) — never landed in a dropped partition. F1 danger demonstrated live: under
REPEATABLE READ **without** the precondition, the count read 0 while a committed row existed —
which is why the READ COMMITTED precondition below is mandatory, not hygiene.

### Alternatives matrix (same fixtures, for the record)

| Cell (abridged) | cur (fec9b2e) | A BYPASSRLS | B1 catalog | B2 executor | C age | D size |
|---|---|---|---|---|---|---|
| Safety, all 11 shapes | **DROP** on 05 (group), 06 (no permissive) | KEPT | KEPT | KEPT | **DROP** everywhere | KEPT |
| Capability under benign FORCE | DROP | DROP | DROP | **refuse** | DROP | DROP |
| Capability under restrictive shapes | refuse | DROP | refuse | refuse | DROP | DROP |
| Attached child, no grant | error (fail closed) | error (fail closed) | refuse | error | **DROP** | DROP |
| Used-then-emptied | DROP | DROP | DROP | refuse | DROP | **KEPT** (starves) |

## Mandatory companions (adversary findings F1–F9, all verified against source)

- **F1 — isolation precondition.** Cleanup never checked isolation; under REPEATABLE READ the
  snapshot predates the lock, and a row committed while the lock waits is invisible to the
  count (demonstrated live). Cleanup must call the existing `transaction_preconditions/1`
  (READ COMMITTED check) at transaction start, like every claim path already does
  (`store/postgres.ex:109,154,231,250,266` — cleanup at `:484` does not).
- **F2 — a refused prune must not roll back the whole cleanup.** Today any prune error rolls
  back the idempotency and nonce deletes too (`:488–495`), and a non-owner worker's failed
  DROP wedges all retention cleanup, RLS or not. The savepoint design above is the fix: a
  refusal is "kept, with reason", and claim/nonce cleanup proceeds. Error classification: a
  `permission denied`/`must be owner` on the prune path maps to a kept-with-reason outcome,
  not `:store_invariant` halting the run (`:1618–1629` needs the prune-path distinction).
- **F3 — name the partition once.** The store passes unqualified names (`:1754`) that LOCK and
  DROP resolve through the caller's `search_path`, while the function resolved them in a
  hard-coded schema — two resolutions, two possible tables. The store already knows the schema
  from `payload_partitions`; LOCK, the checks, and DROP must all use that one
  schema-qualified name (bound to an OID once, inside the savepoint).
- **F5 — relkind allowlist.** `relkind = 'r'` only, inside the savepoint. A sub-partitioned
  child (`p`) reads `pg_relation_size = 0` (which is why D alone is unsafe) and a foreign
  partition would count through FDW where BYPASSRLS does not reach; both are refused.
- **F8 — `pg_temp` last** in any remaining fixed `search_path` on the cleanup connection.
- **F9 — delete the claims count** (above).

Mooted by this design: F4 (no privileged role to hold ADMIN/SET on), F6 (no EXECUTE grant, no
caller-chosen date oracle — the decision runs as the cleanup driver), F7 (no PG16+ membership
syntax in the shipped path; the owner-savepoint sequence is plain SQL available on every
supported version — the docs' PG floor stays as is).

## What this deletes

The 1.9.0 line is unpublished, so this is removal, not teardown:

- `priv/templates/migrations/rls_prune.exs` — the whole template (role, SECURITY DEFINER
  function, blocklist guard, prune policies, child policy copying, the ACL/SET dance).
- `--rls-prune` / `--app-role` in `mix ash_onetime.gen.migrations` (`parse_rls_prune!`,
  `render_rls_prune`).
- In `store/postgres.ex`: `prune_function_schema/1`, `function_partition_empty?/3`,
  `guarded_partition_empty?/2`, and `copy_parent_row_security/3`'s policy/flag copying in
  `roll_partitions` (children no longer need parent policies copied for the prune; consumers'
  own queries go through the parent, whose policies govern).
- The claims count in the emptiness decision; `test/ash_onetime/store/rls_prune_test.exs`
  tier 2 (replaced by the matrix suite); the "Row-level security" section of
  `documentation/operations.md` (rewritten: see install steps); the `:row_security_blocked`
  error-code semantics narrow to the prune's kept-with-reason telemetry; CHANGELOG entry for
  the 1.9.0 line updated to describe the final design.

## Consumer install steps

- **Nothing new to install.** No role, no bootstrap, no superuser, no extra migration. The
  existing operational rule stands: under RLS, the table owner drives cleanup (`DROP` needs
  ownership — unchanged).
- **A consumer that does nothing** (ash_metered today: `partition_limit: 0`, rolling off; AA,
  Commerce if they use the default worker): identical behavior for RLS-off installs; for RLS
  installs whose worker is not the owner, partitions are kept with a reason and — once F2
  lands — claim and nonce cleanup keeps running instead of wedging (an improvement over the
  current shipped behavior, which the adversary showed halts all cleanup).
- Ops doc: document the READ COMMITTED requirement (F1) and that per-run telemetry now reports
  per-partition kept-refusals (reasons: not-empty, not-a-plain-child, not-owner, isolation,
  DDL-blocked).

## Why the rivals lost

- **A (BYPASSRLS role)** — a true invariant and it deletes the same code, but it needs a
  one-time superuser on every install (CREATEROLE cannot grant BYPASSRLS — probed), it leaves a
  permanent cluster-wide bypass-capable principal whose ADMIN holders must be governed forever
  (F4), and its capability equals B2-owner only where the owner drives cleanup anyway. It
  stays the documented fallback if review rejects the transient `NO FORCE` DDL, with its
  conditions (fresh database-scoped role, SET-in-window only, `server_version_num ≥ 160000`
  gate, relkind gate, F1/F2/F3 shared).
- **B1 (catalog positive check)** — the blocklist class rebuilt as an allowlist: its safety is
  a maintained enumeration (policy names, quals, cmd coverage, membership depth, two RLS flags,
  OID-vs-name matching), which is the defect class itself. Rejected on that ground even though
  every probed shape passed.
- **B2 (executor-gated, definer variant)** — sound but never prunes under any RLS-enabled
  shape (loses even benign cell 02 and attached-clean cell 08 via the claims table), and with
  F2 un-fixed it would stop all cleanup. B2-owner keeps its mechanism and drops its cost by
  moving the exemption to the driver the deployment already requires.
- **C (drop by age)** — rejected on code evidence: nothing bounds `retain_until` relative to
  `response_partition` (`resource.ex:152`, `store/postgres.ex:623`–652), a wrong drop deletes
  payloads of live claims, and the delete-guard trigger then makes those claims permanently
  undeletable (`install.exs:206`–221). Also drops non-empty partitions with RLS off.
- **D (`pg_relation_size = 0`)** — unsafe alone (sub-partitioned/foreign children read 0),
  starves on used-then-emptied partitions until VACUUM truncates; subsumed by the relkind gate
  + real count.

## Review set (per the skill; receipts under `.kimosabe/reviews/`)

- Adversary: `2026-11-09-rls-prune-adversary-claude.md` — independent Claude pass, design
  charter, read-only, ten findings (F1–F10), all accepted after source verification; it
  materially changed the design by widening the frame to "consumer configuration" (F1/F3/F5
  are not RLS) and by exposing the refusal-outage (F2).
- Judge: `2026-11-09-rls-prune-judge-claude.md` — independent fresh session; accepted all ten
  findings (two widened), rejected B1/C/D on the invariant criterion, ruled for **B2-owner**
  as above and demanded the executable proof it now has. Environmental note: the Codex peer
  could not run from this host (its launcher needs `node`, not on the sandboxed shell's PATH —
  attempt receipt `2026-11-09-rls-prune-judge-codex.md`), so adversary and judge both ran as
  separate Claude processes; family distinctness from the author (GLM) held, family
  distinctness between adversary and judge did not. If i-1 wants a cross-family judge pass on
  this design, that is one more attended dispatch.

## Open items and implementation boundary (not started, per instruction)

- Implementation = the store changes in "Mandatory companions" + the owner-savepoint prune +
  the deletions above. Its tests are this adversarial matrix written RED-first against the
  real migration output (all cells, both concurrency probes, the FORCE-restore assertion, the
  F1 danger/refusal pair, the event-trigger and non-owner cells), per the owner's directive.
- One design decision left open for review: whether kept-with-reason refusals surface as a new
  structured reason field on the cleanup result (preferred) or as telemetry events only.
- The `_default` partition is load-bearing for the no-loss race argument (late inserts route
  there); the ops doc should say dropping it converts "routed, no loss" into "insert errors" —
  still fail-closed, but worth stating.
