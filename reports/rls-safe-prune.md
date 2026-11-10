# RLS-safe payload prune — 1.9.0 build report

**Published November 10, 2026 (owner approved).** Tag `v1.9.0` → `22b31ba`;
[hex.pm/packages/ash_onetime/1.9.0](https://hex.pm/packages/ash_onetime/1.9.0)
(checksum `fca832970d2cfa7e54ed30db20179c5a5bd3440d22434582fb8e605b60507209`).
Landed through `kimosabe-land` (CI run 42798435746: Ash 3.37.2, Ash latest, OTP 28 and
release gates green; 767/767 suite checks, 174/174 mutations, optional matrix, all four
source livebooks); tag CI run 42803129480 green on the same SHA. Post-publish verified:
hex.pm `latest_version` is `1.9.0`; the release's `ash` requirement is the floating
`>= 3.37.2 and < 4.0.0` and `ash_sql` is `~> 0.8 and >= 0.8.6`; all four livebooks execute
against the published package (`scripts/check_livebooks.exs --published`).

**Release check (replaces the owner-relayed i-1 answer).** The owner handed release
verification to this session. Review of `76b028e..90f0b2e` confirmed i-1's four
findings fixed, and found one regression in the finding-2 fix: with the parent's ACCESS
EXCLUSIVE lock taken first, a full `count(*)` of each occupied past partition stalled
every tenant's payload traffic for the length of the scan on every cleanup run. `82913be`
replaces it with `SELECT EXISTS (SELECT 1 FROM <partition>)`, which stops at the first
live row and resolves no function through `search_path`; the count and catalog-count
mutation rows were retargeted and pass RED→GREEN. `22b31ba` adds `kci/**` to the CI push
trigger so `kimosabe-land` gets its pre-merge run.

The four i-1 findings and the supported AshSql floor repair are implemented and verified.
The owner requested covering checks only for this continuation; no full suite or
all-mutation battery was rerun. Earlier complete results are distinguished below.

## Commits and review route

Earlier commits are unchanged. Starting local HEAD was `76b028e` (GLM's B2-owner
implementation); origin/main remains `43f1be5`.

- `862767a` — pin all nine GitHub Action uses to upstream commit SHAs, separately
  as required by the brief.
- `fc41141` — fix i-1's four findings, executable regressions/mutations,
  refusal docs/livebook, AshSql floor 0.8.6, and Oban lock 2.24.2.
- This report/design tie-out is committed after those implementation commits.

Implementation review range: `76b028e..fc41141`. Including this report/design commit,
the handoff range is `76b028e..HEAD`; the full unpushed range is `43f1be5..HEAD`.
**i-1 answer: not received.** The owner relays the committed range to b-1/i-1 and
pastes back either “push” or specific findings. No direct reviewer dispatch or
sub-agent was used. No push is authorized until that answer returns. Suite-wide
landing then follows the owner's `kimosabe-land` rule; it is not started here.

## Scope and acceptance — DONE

The class is a destructive emptiness decision that tenant RLS, consumer DDL hooks,
search_path, or lock ordering can make unsafe or unavailable. The accepted
owner/savepoint design in `reports/rls-prune-design.md` supersedes the brief's earlier
dedicated-role/SECURITY DEFINER proposal: no new role, migration option, function,
grants, or application-role membership. Child policy copying remains for direct
tenant reads. No consumer repository or tenant data is changed.

Mapped surfaces: `Postgres.cleanup/3`, savepoints, `Store.cleanup/3` telemetry,
cleanup types, prune CLI, real-PG matrix, mutation registrations, operations,
upgrading, CHANGELOG, livebooks, version/package metadata, dependency requirements,
exact-minimum consumers, and CI. Build/check execution is routed through
kimosabe-remote on kbuild. The database is real PostgreSQL 18.6 in a throwaway
emptyDir pod in the dev box cluster's ephemeral namespace (`rls-fixes`, port 37526).
Tests create fresh NOSUPERUSER NOBYPASSRLS CREATEROLE owners and separate app roles;
they assert the owner flags before pruning. Superuser bootstrap only installs the
DDL hooks/FDW fixture; it does not drive the prune under test.

## i-1 findings — all DONE

Original: `.kimosabe/reviews/2026-11-09-76b028e-i1-review.md` and adjacent SQL.
The five corrected review tests ran against the untouched `76b028e` Postgres/Store
implementations first: **0/5 passed, five expected reds**. Infrastructure/fixture
errors were excluded from that evidence. Fixed code then passed the RLS matrix,
including all 17 cases in the latest covering run.

1. **HIGH, FORCE/GUC safety.** An explicit catalog FORCE recheck follows NO FORCE;
   FORCE still on means kept with `force_reapplied`. `row_security=off` is armed
   before ALTER and stays load-bearing through count; the “belt only” comment is
   removed. **RED:** the old implementation had no FORCE refusal reason; a real
   hook requiring the GUC off before ALTER kept both empty candidates (expected
   two drops). **GREEN:** the re-FORCE hook returns `force_reapplied: 2`, preserves
   the hidden payload and FORCE, while the GUC-checking hook permits empty drops
   and restores caller settings. **Mutations:** `rls-prune-force-gate` and
   `rls-prune-row-security` each failed its named assertion, restored exact bytes,
   and executed GREEN. Removing only the FORCE gate remains data-safe because the
   GUC then errors; its mutation pins the explicit refusal contract. The GUC hook
   independently pins the required setting even with the FORCE gate present.
2. **HIGH, availability.** Bounded local lock_timeout (default 2,000 ms;
   `:partition_prune_lock_timeout_ms`, valid 1–5,000) precedes ONLY-parent ACCESS
   EXCLUSIVE, then ONLY-child ACCESS EXCLUSIVE. No late parent upgrade. Timeout
   keeps the candidate with `lock_unavailable`; caller GUCs restore. **RED:** the
   old prune held one child ACCESS EXCLUSIVE lock while waiting on the parent
   (expected zero), exposing the reader-to-child cycle. **GREEN:** a real held
   parent reader sees no child lock while prune waits; the reader reaches the
   child without deadlock; prune returns `lock_unavailable: 1`; prune and an
   unrelated current-month insert finish under 1,500 ms with a 500 ms lock timeout;
   caller lock_timeout returns to 7 seconds. **Mutations:** `rls-prune-parent-lock`
   fails the zero-child-lock assertion; `rls-prune-lock-timeout` exceeds the
   three-second await. Both restored exact bytes and executed GREEN.
3. **MEDIUM, refusal observability.** `payload_partitions_kept` retains all kept
   candidates, including occupied ones. Add `payload_partitions_refused`, a sparse
   reason-to-count subset. Emit `:partitions_kept` telemetry only for that map's
   sum; do not add telemetry metadata. Update types, CLI, docs, and CHANGELOG.
   **RED:** an occupied result had no refusal map and emitted routine kept
   telemetry. **GREEN:** occupied returns `%{}` refusals and no event; non-owner
   returns `not_owner: 1` and one refusal event. **Mutation:**
   `rls-prune-refusal-telemetry` restored the old total-based condition, failed,
   restored exact bytes, and executed GREEN.
4. **LOW, search_path.** The prune uses `pg_catalog.count(*)`; discovery/facts use
   qualified catalogs, regclass, current_setting, and clock/schema functions.
   Completion/backlog counts are also catalog-qualified. **RED:** a real consumer
   count(*) aggregate returns 0 on an occupied partition; old cleanup dropped
   both candidates instead of one. **GREEN:** shadow count reads 0, catalog count
   reads 1, cleanup drops only the empty sibling and preserves the payload.
   **Mutation:** `rls-prune-catalog-count` unqualifies the aggregate, fails,
   restores exact bytes, and executes GREEN.

**FDW proof — DONE.** A real postgres_fdw child reads the same server as the app
role: remote RLS sees 0 while the authoritative table holds 1. Prune refuses
`not_plain_child: 1`. Deleting relkind reaches PostgreSQL's foreign-lock rejection
(42809), returning `error: 1`; the mutation reds and restores green. This pins the
physical-refusal contract, not a claim that removing this gate alone loses data.
The fixture reads SHOW port, handles loopback-trust mapping in bootstrap, and uses
unprivileged roles for actual queries/pruning. Dynamic-repo test queries resolve
the PID explicitly; bound relation names use text::regclass.

## Release and security tie-out — DONE

- Version is 1.9.0 in mix.exs; README, upgrading, and all four livebooks target it.
- No-RLS cleanup keeps its empty-past-partition behavior; result keys are additive.
- CHANGELOG/upgrading explicitly describe READ COMMITTED refusal, savepoint refusal
  preserving claim/nonce deletes, bounded lock waits, and refusal-only telemetry.
- Matrix retains tenant isolation, restrictive/group policies, default deny,
  subpartitions, direct-child reads, FORCE restoration, and in-flight inserts.
- Source idempotency livebook includes executable claims-only maintenance and the
  counts contract. All four source notebooks passed before this continuation.
- All nine Action uses are full upstream tag-resolved SHAs (checkout v7,
  setup-beam v1 peeled commit, cache v6). YAML parses; all nine pins pass the
  40-hex check. CI itself is held for i-1.
- **AshSql floor 0.8.6:** root lock was already safe at 0.8.8, but the published
  requirement admitted [0.8.4](https://hex.pm/packages/ash_sql/0.8.4) and
  [0.8.5](https://hex.pm/packages/ash_sql/0.8.5), both security-retired for a query-cache
  issue fixed in [0.8.6](https://hex.pm/packages/ash_sql/0.8.6). **RED:** the stricter
  test failed on accepted 0.8.4; a real exact-0.8.4 consumer resolved and failed
  `mix hex.audit`. **GREEN:** require `~> 0.8 and >= 0.8.6`, retain runtime:false,
  and align package metadata, current docs, ADR 0004 amendment, and core-floors.
  The test rejects .4/.5 and accepts .6. The changed `deps-ash-sql-floor` mutation
  lowers the floor to .5, fails the exact .5 assertion, restores bytes, and
  executes GREEN. Every positive matrix consumer now runs `mix hex.audit`.
- Oban lock 2.24.1 → 2.24.2 repairs release currency drift; its optional consumer
  requirement remains `~> 2.23` and runtime-excluded.
- An accidental catalog alias edit in the uncommitted partition-existence fallback
  was removed during final diff inspection, restoring that line to `76b028e`.
  Partition and roll-contention tests pass in the covering run.

## Verification — DONE results, with boundaries

Before the owner's covering-only continuation, the last complete routed gate passed:
**174/174 mutations** (RED → byte restoration → executed GREEN) and **767/767
full-suite checks** (23 properties, 744 tests), with `ASH_ONETIME_RLS_PRUNE_TESTS=1`.
It also passed format, dev/test compile, 17 RLS tests, strict Credo, dev/test
Dialyzer (zero errors), deps.audit, hex.audit, dependency currency, codegen and
cheat-sheet freshness, docs, all four source livebooks, and package/unpacked
consumer checks. Its optional matrix exited green but revealed the retired floor;
that prompted the repaired checks above. This historical run precedes the stricter
AshSql test/floor edit; it is not a full-suite result for the final commit.

The covering-only continuation passed:

- Format; dev/test compile warnings-as-errors; **39/39 covering tests**:
  dependency_security_test, rls_prune_test (17 cases), partition_test, and
  roll_contention_test, seed 0, real PostgreSQL 18.6.
- Mutation self-test/site audit and the changed `deps-ash-sql-floor` row RED→GREEN.
- Strict Credo; root deps.audit and hex.audit; docs warnings-as-errors.
- Package metadata/90-file inspection and an unpacked zero-config compile/test.
- Optional matrix: eight positive consumer configurations, including exact Ash
  3.37.2/AshPostgres 2.15.2/AshSql 0.8.6; every graph audited; four expected
  resolution conflicts (Igniter 0.8.3, Mint 1.10.1, AshSql 0.8.4 and 0.8.5).

The final documentation bytes were rechecked with format, docs warnings-as-errors,
Hex build, package inspection, and the unpacked consumer test, all GREEN. Final
archive SHA-256: `c0f312efc673103adbe8ffe6a9e41dc407a2a15cc496fc683ae88b2b8bff142e`.
The archive was removed after verification. Staged changes passed the redacted
gitleaks scan and git diff whitespace check before local commits.

Local ignored logs: `.kimosabe/scratch/rls-fixes/verified.log` (five product reds),
`verified-release.log` (earlier complete gate), `floor-red.log`, `floor-covering.log`,
and `final-doc-package.log`. These are supplementary; named tests/mutations
reproduce the assertions. No full-suite or all-mutation command was run in this continuation.

## Remaining items — classified

- **DONE — push, tag, Hex publish, published-mode livebooks, OTP 28 and floating-Ash
  CI lanes** (see the top of this report).
- **OPEN — needs another product's unbuilt work: Agent Access's upgrade from its
  `~> 1.8.0`/locked 1.8.0 dependency to 1.9.0.** Live maintenance adoption was not
  executed here. Its requested policy-helper source check is **DONE**: it checks
  pg_policy before CREATE, so copied tenant_isolation/ledger_maintenance names do
  not produce duplicate CREATE statements. No consumer files/data were changed.

Likely operational pressure: a persistently busy parent can keep refusing with
lock_unavailable; successful drops hold locks until the outer transaction ends.
The operations guide calls for bounded batches and short owner-run transactions.
Native macOS build execution was not checked; all build/test work was routed to
kbuild as required. Further full-suite runs are forbidden locally by the owner;
CI after review is the next whole-suite gate.

All owned verification runners completed. The owned ephemeral `rls-fixes` run was
removed after verification; no mutation fragment or generated package archive remains.
