# Context boundaries

A context boundary admits an append only if nothing relevant changed since the caller
looked: the second admission shape after keyed effects. `:idempotency` and
`:one_time_nonce` admit exactly once per key; a context boundary admits a write when the
facts it decided on are still the facts.

The pattern answers rules that span many records without designing a lock row for each
rule in advance — "refund only if no other refund landed on this capture since I read
it", "invite once per email per realm even when two invitations race", "claim the slot
if the schedule did not move".

## The shape

A resource opts in by naming an append-only fact table. Each fact carries a monotonic
`seq` (from a per-table identity), a `type`, and a `tags` array (GIN-indexed); every
call is scoped by an explicit `:tenant`, and the fact table is append-only by trigger.

```elixir
use Ash.Resource,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshOnetime.Resource]

postgres do
  table "refunds"
  repo MyApp.Repo
end

context_boundary do
  fact_table "refund_facts"
end
```

Create the table with the migration generator:

```sh
mix ash_onetime.gen.migrations --repo MyApp.Repo --fact-tables refund_facts
```

## Read, decide, append

`read/3` returns the facts a query matches plus the cutoff — the highest matching `seq`
the caller saw:

```elixir
{:ok, %{facts: facts, cutoff: cutoff}} =
  AshOnetime.Boundary.read(Refund, {:tag, "capture:#{capture_id}"}, tenant: tenant)
```

A query is a boolean expression over tags and types:

```elixir
{:tag, "capture:42"}
{:all, [tag: "capture:42", type: "refund"]}
{:any, [tag: "order:7", tag: "order:8"]}
{:not, {:tag, "voided"}}                       # only inside an :all that also anchors
```

Every query must be **tag-anchored**: any fact it matches carries at least one tag the
query names. That is what makes the lock set cover the context — a query naming no tag,
or one a bare `:type` branch or a negation could satisfy, is refused at validation.

After deciding on the facts, `append_if/5` appends inside the caller's transaction:

```elixir
Repo.transaction(fn ->
  case AshOnetime.Boundary.append_if(Refund, {:tag, "capture:#{capture_id}"}, cutoff,
        [%{type: "refund", tags: ["capture:#{capture_id}"]}],
        tenant: tenant
      ) do
    {:ok, appended} -> # proceed; each fact carries its assigned seq
    {:error, {:context_changed, max_seq}} -> # someone appended first: re-read and decide
  end
end)
```

`append_if/5` never starts a transaction; it requires the caller's open PostgreSQL
`READ COMMITTED` transaction and runs in it — including inside `AshOnetime.Transaction`
flows and on Ash create actions. It takes a transaction-scoped advisory lock for every
tag the query names and every tag the appended facts carry (sorted, keyed by tenant and
tag), checks that no fact matching the query has a `seq` above `cutoff`, then appends. A
changed context answers `{:error, {:context_changed, max_seq}}` — the caller re-reads
and decides again.

## On a create action

`AshOnetime.Boundary.Change` places the same append on a create action. The query,
cutoff, facts, and tenant resolve from literals or `{:argument, name}` /
`{:attribute, name}` references, so the caller's read results ride in as action input:

```elixir
create :refund do
  accept [:capture_id, :amount]
  argument :context_cutoff, :integer, allow_nil?: false
  argument :context_facts, {:array, :map}, allow_nil?: false

  change {AshOnetime.Boundary.Change,
          query: {:all, [tag: {:argument, :context_tag}, type: "refund"]},
          cutoff: {:argument, :context_cutoff},
          facts: {:argument, :context_facts}}
end
```

A changed context fails the action with a typed `:context_changed` error carrying the
seq that moved (`AshOnetime.Error.code/1`); admitted seqs are stamped into the record's
metadata under `:ash_onetime_boundary`. The change composes with `onetime` protection on
the same action — a retried idempotent request replays its stored answer instead of
appending again.

## Why it is correct

Writers of one context serialize on its tags; writers with no tag in common never block.

- **Commit order equals seq order.** A writer allocates its `seq` from the table
  identity while holding its tag locks, and advisory locks release only at commit. A
  competing writer for the same context therefore allocates a later `seq` strictly after
  the earlier writer committed — identity values cannot commit out of order for facts
  relevant to a context. Facts with disjoint tags may interleave freely; they never
  match each other's queries (tag-anchoring).
- **No phantom admission.** The check runs under the locks: any matching competitor is
  either already committed (visible, refuses the append) or still holding a shared tag
  lock (the check blocks until it commits, then sees its fact). A writer cannot slip
  between the check and the append.
- **Fail-closed tenancy.** Every call carries `:tenant`; rows, checks, and lock keys all
  include it. No tenant means no admission.

The concurrency proofs in `test/ash_onetime/boundary_contention_test.exs` pin these
properties on real PostgreSQL: twelve overlapping writers admit exactly one append per
read epoch, disjoint writers proceed while another tag's locks are held (and a blocked
writer refuses only after the holder commits), and twelve retrying writers complete in
`seq` order.

## Context boundary or counter row?

A counter row (locked `FOR UPDATE`) stays the right tool for **hot numeric totals** — a
running balance, a stock level, a budget consumed by many small writes. It is a single
row, the arithmetic is the rule, and contention is bounded by one lock.

A context boundary is the right tool when the rule is **"nothing relevant changed since
I looked"** across records — a per-email invitation, a refund bounded by everything that
already landed on a capture, a release-once credential. It replaces the bespoke
check-then-write (a read, a comparison in application code, a write that races) with one
admitted append, and it needs no lock row designed per rule in advance: new rules are
new tags and new queries on the same fact table.

Both can compose: a counter for the number, a fact for the decision trail.
