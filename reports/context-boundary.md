# Context boundary — build report

**Release line for the owner (not run; publish awaits approval):**

```sh
git tag -a v1.8.0 -m "1.8.0" && git push origin main v1.8.0
env -u ASH_ONETIME_ASH_VERSION mix hex.publish --yes
```

Post-publish: verify hex.pm `latest_version` and the release's `requirements.ash.requirement`, then
`elixir scripts/check_livebooks.exs --published` with `DATABASE_URL` exported.

## What was built

`ash_onetime` 1.8.0 adds conditional append over a context — the second admission shape, taken
from reckon_db's dynamic consistency boundary without the package.

- `context_boundary` DSL section naming a resource's fact table (validated identifier, reserved
  prefix refused, AshPostgres required; compile-time rejection in the transformer, re-asserted in
  the verifier).
- `AshOnetime.Boundary.read/3` — matching facts newest-first plus the cutoff (highest matching
  `seq`, spanning the whole match regardless of the page limit).
- `AshOnetime.Boundary.append_if/5` — inside the caller's READ COMMITTED transaction: one
  transaction-scoped advisory lock per tag (query-named ∪ fact-carried, sorted, tenant-keyed),
  then `NOT EXISTS (matching AND seq > cutoff)`, then the append. Changed context answers
  `{:error, {:context_changed, max_seq}}`.
- Tag-anchored query language (`{:tag,_}`, `{:type,_}`, `{:any,_}`, `{:all,_}`, `{:not,_}`) with
  size bounds; a query a matching fact could satisfy without carrying a named tag is refused —
  that anchoring is what makes the lock set cover the context.
- `AshOnetime.Boundary.Change` for create actions (argument/attribute-referenced query, cutoff,
  facts, tenant), composing with `onetime` protection; typed `:context_changed` action error.
- `mix ash_onetime.gen.migrations --fact-tables a,b` emits the fact-table migration (identity
  `seq`, GIN `tags`, tenant scoping, append-only trigger, reversible). Default generator output
  is byte-identical when the flag is absent.
- Guide (`documentation/context-boundary.md`) with worked examples and the
  boundary-vs-counter-row section; DSL cheat sheets regenerated; CHANGELOG, README, upgrading,
  usage rules, version surfaces all at 1.8.0.

Additive minor: no existing behavior changed; consumers without the section need no migration.

## Red and green (last lines)

Red (new suite against the absent feature):

```
== Compilation error in file test/support/resources/boundary_examples.ex ==
** (CompileError) test/support/resources/boundary_examples.ex: cannot compile module AshOnetime.Test.Support.BoundaryResource (errors have been logged)
```

Green:

```
mix test test/ash_onetime/boundary_test.exs            → Result: 24 passed
mix test test/ash_onetime/boundary_contention_test.exs → Result: 3 passed
mix test                                              → Result: 748 passed (23 properties, 725 tests)
```

Mutation rows (RED demonstrated, exact bytes restored, GREEN confirmed):
`boundary-check-predicate`, `boundary-lock-noop` — both owned by the overlap-proof assertion
`assert admitted == 1`.

## Concurrency proof (real PostgreSQL, real connections)

`test/ash_onetime/boundary_contention_test.exs`:

1. **Overlapping contexts admit exactly one append per read epoch.** Twelve writers, same
   tenant, same tag-anchored query, all at cutoff 0: exactly 1 `{:ok, [_]}`, 11
   `{:error, {:context_changed, _}}`, and the table holds one fact. This is the property the
   two mutation rows attack (neutering the cutoff predicate, or the advisory locks, admits
   many).
2. **Disjoint contexts never block; no phantom admission.** With one transaction holding a
   tag's locks open, twelve writers on disjoint tags all complete while it is held; a writer on
   the held tag blocks while the holder's fact is uncommitted (refuted completion for 300 ms)
   and refuses only after the holder commits, naming the holder's `seq`. Identity values
   committing out of order therefore cannot slip a matching fact past a check.
3. **Commit order equals seq order.** Twelve retrying writers (read → append → on
   context_changed re-read) all admit; the admitted `seq`s arrive strictly increasing in
   completion order, and the table holds exactly twelve.

The mechanism: a writer allocates `seq` while holding its tag locks, and the locks release only
at commit, so any competing writer for the same context allocates a later `seq` strictly after
the earlier one committed. Writers with disjoint tags share no lock and never block.

## Adoption inventory

**Not inventoried.** The brief asks for every check-then-write rule across Commerce, BA, and
Agent Access; those repositories sit outside this session's data boundary (the
sensitivity-routing guard refuses every read of them — verified), so no verified inventory is
possible from here. The brief's candidate list, unverified:

| Product | Candidate rule (per the brief) | Boundary fit (expected) |
| --- | --- | --- |
| Commerce | Refunds never exceeding captured amounts across concurrent refunds | Replace bespoke check-then-write; one admitted append per read epoch |
| Commerce | The one goodwill budget across agents | Counter row stays right for the numeric total; boundary for the decision |
| Commerce | Stock holds | Boundary if the rule is "nothing relevant moved"; counter for a hot numeric level |
| Agent Access | A credential released once per instruction | Replaces bespoke once-per-X logic with one admitted fact |
| Agent Access | Limits across purchases | Boundary for "nothing relevant changed since read" rules |
| BA | Colleague/owner invitations once per email per realm | Natural fit: one admitted invitation fact per (email, realm) context |
| BA | `CumulativeLedger` (BA-49, ADR 0041) | Already correct; convert only if an inventory shows real simplification |

Each product's change becomes its own brief; run the inventory from a session that can read
those repositories.

## Not proved / not done

- The adoption inventory above is unverified for the stated reason.
- The release battery's remaining tag-time checks were not run in full here (mutation matrix
  `-- all`, livebook execution, optional-integration matrix); the two new mutation rows were
  run individually and the package/consumer check, docs, codegen, and cheat-sheet gates passed.
- Dependency floors were NOT raised: the lock moved (ash_sql 0.8.8, ecto 3.14.3, ash 3.37.3 —
  `hex.audit`/`deps.audit` were red on main's committed lock from fresh advisories
  EEF-CVE-2026-118391 and the ash_sql retirement, and are green again), but the declared
  ash/ash_sql floors still admit the advised-against versions for consumers. ADR-0004's
  derivation rule would raise them (ash_sql `>= 0.8.6`, ash `>= 3.37.3`); that is its own
  floor-sweep slice (CI matrix, doctor tripwires, ADR amendment) and the owner's call.
- No telemetry event for `:context_changed` admissions (the brief did not ask; the typed error
  carries the deciding `seq`).
