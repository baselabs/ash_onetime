# External effects and recovery

An external peer cannot share the local PostgreSQL transaction. Protected external effects
therefore use a committed recovery point plus a peer operation key instead of pretending the
two systems commit atomically.

The adapter implements the ExternalEffect execute and recover callbacks. Both receive
the authoritative claim UUID as the operation key and must pass it unchanged to the peer's
idempotency and recovery surfaces.

1. PostgreSQL commits a claim in `processing` before any peer call.
2. A fresh request calls `execute(operation_key, subject, context)`.
3. A retry of a processing claim takes the pre-peer claim lock described below and then calls
   `recover/3`; a concurrent retry that cannot acquire the lock within the configured wait
   is refused with `:request_in_progress` before `recover/3` runs.
4. `{:ok, result}` is finalized locally while the claim is locked.
5. `:absent` is proof that execution never happened; only then may the same operation key be
   executed.
6. `:unknown`, an exception, malformed output, disconnection, or timeout remains ambiguous.
   It never permits a second execute or local finalization.

If the caller dies before peer execution, recovery can prove absence and execute once. If it
dies after peer success, recovery returns the existing peer result and local finalization
continues without a second peer effect. If local finalization rolls back, the processing
claim remains a recoverable point.

External processing claims survive every maintenance path, even after every retention and
abandonment horizon. Reap selects only claims fixed as `local` at insertion. Cleanup selects
only completed claims; response expiry, prune and roll preserve the recovery point and its
per-attempt outcomes. An unresolved operation keeps its original UUID until recovery completes.
Storage for operations that never resolve is unbounded. Monitor maintenance's `kept_external`
count and investigate the oldest unresolved operations through your recovery workflow.

A new external reservation commits `effect_local = false` and `effect_attempt = 1`. Each retry
commits the next attempt before taking the caller lock. Under that lock it checks the granted
attempt again. A caller superseded by a newer grant returns `:request_in_progress` without
calling the peer. A completed claim replays, and a stale attempt cannot complete it.

If recovery cannot prove a result, a separate, unlinked worker records `held` for that exact
attempt. After ambiguous execution followed by authoritative absence, it records
`absent_proven` and returns `:external_effect_unavailable`. These records commit independently
of an aborted caller transaction. A late record for an older attempt never changes the newer
attempt's state. An outcome that could not be recorded emits `outcome_unrecorded`; the typed
recovery error remains the caller's result, and the claim remains non-reapable.

Adapters must make execute idempotent by operation key and make recover authoritative. A
stub that merely records the request proves only that the package produced a shape; peer
conformance requires a live peer contract. External effects are idempotency-only because a
nonce cannot safely recover or replay a response.

## Concurrent retries: the pre-peer claim lock (normative)

Every external claim-lock statement uses `external_lock_timeout_ms`, including the
immediate replay load and the finalize load. A lock timeout emits a processing conflict
and returns `:request_in_progress`. The package restores the caller's previous lock timeout
after the claim lock and its joined claim, payload and outcome read, before running consumer work.

Before any peer call, the package takes the claim row `FOR NO KEY UPDATE` in the caller's open
transaction — a **pre-peer claim lock** with a bounded wait (`external_lock_timeout_ms`,
default 2000, ceiling 25000; ADR-0010). A same-key retry that arrives while the original is
between its committed claim and its finalization now blocks on that row:

- If the original settles within the wait, the retry proceeds under the lock — recovering
  or replaying exactly as a sequential retry would.
- If it does not, the retry fails with `:request_in_progress` — the same semantic the local
  (non-external) path already returns for a concurrent same-key request.

Two `execute` calls under one operation key therefore cannot overlap at the peer: the lock
is held across the peer call and released only when the caller's transaction ends. This is
observed on a live PostgreSQL in `test/ash_onetime/external_contention_test.exs`: a retry
arriving while the original is paused before its peer call, and one arriving while the
original is mid-execution at the peer, both block on the claims row (observed via
`pg_blocking_pids`), time out at the configured wait, and are refused with
`:request_in_progress` — the ledger shows exactly one execute under one key. A dead caller
releases its backend's locks, so dead-caller recovery is unchanged (same file, "recover runs
inside the retry caller's open transaction").

The lock binds the claim UUID, logical key and granted attempt. Every caller lock uses
`FOR NO KEY UPDATE`, followed by a joined read in a new statement without a lock clause.
That read sees outcomes committed while the caller waited for the claim. Both statements
use the armed timeout; the grant worker keeps `FOR UPDATE`. Outcome insertion
uses the foreign key's compatible `FOR KEY SHARE`, so recording an ambiguous result does not
wait on its own caller. The outcome worker arms the protection's lock timeout and uses its
own connection, including when a callback has already aborted the caller's transaction.

Why the lock exists — the race it closes was real: before it, the package held no lock
between the committed claim and finalize, so an honest in-flight retry truthfully recovered
`:absent` and executed under the same operation key while the original's execute was still
in flight. The peer contract still carries the residue the lock cannot cover:

1. **The peer MUST enforce idempotency by operation key** — a *sequential* retry after the
   original's transaction ended, with a lying `:absent`, still induces a redundant execute
   under the same key. A correct peer absorbs it.
2. **The peer SHOULD claim the key atomically** (a single insert-on-key statement, recorded
   on receipt before processing the effect): with the pre-peer lock in place, atomicity is
   no longer the only defense against concurrent same-key executes — but a peer that
   deduplicates atomically is correct under every retry interleaving, including any future
   path that does not take the lock.

The package's own guarantee is unchanged and observed: the finalize row lock leaves one
local effect and one stored response regardless of retry pressure.

## The adapter execution environment (normative)

Both callbacks run **inside the caller's open PostgreSQL transaction** — the action's
transaction is open on the caller's connection while `execute/3` and `recover/3` run — and
the package applies **no timeout** to either callback. Observed per callback on a live
PostgreSQL in `test/ash_onetime/external_contention_test.exs`: "the adapter callbacks run
inside the caller's open transaction" (`execute/3` — which also reads the caller's backend
from `pg_stat_activity` while the callback is paused and observes it `idle in transaction`
with an open `xact_start`) and "recover runs inside the retry caller's open transaction"
(`recover/3`). An open transaction on a checked-out connection holds that pooled connection
and an idle-in-transaction backend for as long as the callback runs.

An adapter MUST bound its own peer call (its own HTTP timeout, deadline, or circuit): an
unbounded callback holds a pooled connection and an idle-in-transaction backend for as long
as the peer stalls, and at finalize the claim row lock as well. Note that after an ambiguous
`execute/3` the package calls `recover/3` **immediately, in the same request and
transaction** — so a request that executes ambiguously holds the caller's transaction for up
to two adapter timeouts. The package's other external callbacks (verifiers, minters) are
time-bounded by the package; the effect callbacks are bounded by the adapter.

### Sizing the action's transaction timeout

The protected action's transaction stays open on the caller's connection for the whole
request: the committed claim, the peer calls and finalization. The host repo's `:timeout`
(Ecto's default is 15 seconds) bounds that transaction. The committed claim runs on a second
connection with its own 30-second bound, which waits up to `external_lock_timeout_ms` for a
claim lock. If the repo `:timeout` expires first, DBConnection ends the action's transaction
and the request fails closed: no local effect commits, and the claim is recovered on retry.

Set the protected action's repo `:timeout` above the sum of `external_lock_timeout_ms`, the
slowest expected claim write and two adapter timeouts (an ambiguous `execute/3` is followed by
`recover/3` in the same transaction). The repo configuration's `:timeout` is the default for
every operation, transactions included:

```elixir
config :my_app, MyApp.Repo, timeout: 60_000
```

## The adapter MUST prove absence (normative)

`:absent` from `recover/3` is **authoritative proof**, not a default. The package trusts it
unconditionally and re-executes under the same operation key when it arrives. This trust is
inherent to the design — it is how the protocol recovers a caller that died before the peer
recorded the effect — and it is not fixable at the library layer.

An adapter that returns `:absent` for an effect that DID execute defeats the guarantee: the
package will issue a redundant `execute` with the same operation key. Whether that redundant
execute becomes a duplicate side effect depends on the peer:

- A correct peer that enforces idempotency by operation key deduplicates the second execute
  (its stored result is stable, and the duplicate is absorbed). This is the case the package
  is safe against by construction.
- A peer that does NOT enforce idempotency by operation key records the duplicate effect.
  This is a double-spend, and it is the peer's failure, not the package's.

The defenses are independent and both are required:

1. **The adapter's `recover/3` MUST prove absence** by querying the peer's real idempotency
   key store. Returning `:absent` without a real query (a stub, a default, a cached negative)
   is a contract violation. Every uncertain, exceptional, or malformed outcome is `:unknown`,
   never `:absent`.
2. **The peer MUST enforce idempotency by operation key** so a redundant execute is
   absorbed. With the pre-peer claim lock preventing concurrent same-key executes, the
   binding case is sequential: a lying `:absent` after the original's transaction ended
   still induces a redundant execute under the same key, which only the peer absorbs. The
   peer SHOULD claim the key atomically (see the concurrency section above).

The package supplies the operation key (the authoritative committed claim UUID) to both
callbacks; the adapter passes it unchanged to the peer's idempotency and recovery surfaces.
The combination of (1) and (2) is what makes external effects safe: the package's `:absent`
trust is correct because a correct adapter proves absence, and a correct peer deduplicates
the redundant execute that a lying adapter would induce. Remove either defense and the
guarantee degrades to the honesty of whichever remains.

## Mapping a real peer's outcomes to `:absent` and `:unknown`

`:absent` is the single highest-consequence decision in the protocol: the package trusts it
unconditionally and re-executes on it. Mapping a real peer's responses is where adapters
fail. The rule: **only an authoritative, read-your-writes "no such operation" is `:absent`;
everything else — including a not-found you cannot prove is authoritative — is `:unknown`.**

| Peer outcome | Disposition | Why |
| --- | --- | --- |
| Stored result found by operation key | `{:ok, result}` | The known-result resume path. |
| Definitive "not found" from the **authoritative** key store, read-your-writes | `:absent` | Proof the effect never happened; safe to re-execute under the same key. |
| "Not found" from a replica, cache, or any store that can lag | `:unknown` | Replica lag can hide a just-written effect; 404 here is a double-spend, not an absence. |
| 5xx, rate-limited, overloaded | `:unknown` | The peer's state is unknown; never an absence proof. |
| Timeout / connection refused / DNS failure | `:unknown` | The request may or may not have been applied. |
| Malformed, unparseable, or unexpected-shape response | `:unknown` | You cannot prove what the peer did; fail closed. |
| Auth failure on the recovery surface | `:unknown` | The store was not queried authoritatively. |

A worked HTTP adapter (shape only — bind it to your peer's real idempotency endpoints):

```elixir
defmodule MyApp.PaymentPeer do
  @behaviour AshOnetime.ExternalEffect

  @receive_timeout :timer.seconds(10)

  @impl true
  def execute(operation_key, subject, _context) do
    # The adapter MUST bound its own call: the package applies no timeout to this
    # callback, and it runs inside the caller's open transaction.
    case req_post(operation_key, subject) do
      {:ok, result} -> {:ok, result}
      _other -> {:error, :outcome_unknown}
    end
  end

  @impl true
  def recover(operation_key, subject, _context) do
    case req_get(operation_key, subject) do
      {:ok, result} -> {:ok, result}
      :absent -> :absent
      :unknown -> :unknown
    end
  end

  # The peer must enforce idempotency by operation key. An atomic claim on receipt
  # (INSERT ... ON CONFLICT or its equivalent) is the recommended implementation;
  # it also absorbs callers outside this library's pre-peer lock.
  defp req_post(operation_key, subject) do
    Req.post(peer_url(operation_key),
      json: effect_request(subject),
      connect_options: [timeout: @receive_timeout],
      finch: [pool_timeout: @receive_timeout],
      receive_timeout: @receive_timeout,
      request_timeout: @receive_timeout,
      redirect: false,
      retry: false
    )
    |> map_response()
  end

  defp req_get(operation_key, subject) do
    Req.get(peer_url(operation_key),
      params: effect_request(subject),
      connect_options: [timeout: @receive_timeout],
      finch: [pool_timeout: @receive_timeout],
      receive_timeout: @receive_timeout,
      request_timeout: @receive_timeout,
      redirect: false,
      retry: false
    )
    |> map_response()
  end

  defp map_response({:ok, %Req.Response{status: 200, body: body}}) when is_map(body),
    do: {:ok, body}

  # 404 is absence ONLY from the authoritative key store itself. If the URL hits a
  # replica or an edge cache, return :unknown instead — read-your-writes is required.
  defp map_response({:ok, %Req.Response{status: 404}}), do: :absent

  defp map_response(_other), do: :unknown
end
```

The timeout options cover connection establishment, pool checkout, socket receives, and
the response as a whole; redirects and automatic retries are disabled. They are separate
HTTP phase limits, not a claim that the entire callback lasts exactly ten seconds. Adapt
them to your request deadline and peer contract. See [Req's connection options](https://hexdocs.pm/req/Req.html#new/2)
and [Finch's request options](https://hexdocs.pm/finch/Finch.html#request/3).

The `:unknown` arm of `map_response/1` deliberately swallows 5xx, timeouts, transport
errors, and malformed bodies with one clause: every one of them is ambiguity, and ambiguity
never authorizes a second execute or a local finalization the evidence does not support.
What the package does with an ambiguous `execute/3` is precise, and worth reading once:

- `execute/3` returns `{:error, :outcome_unknown}` → the package immediately calls
  `recover/3` in the same request and transaction.
- That recovery returning `{:ok, result}` means the effect **did** land — the package
  finalizes with the recovered result and the claim completes.
- That recovery returning `:absent` means the effect provably never happened, but the
  package still declines to loop (`:external_effect_unavailable` to the caller); the claim
  stays `processing` and a later retry recovers it.
- That recovery returning `:unknown` leaves the outcome genuinely unknown
  (`:outcome_unknown` to the caller); the claim stays `processing` and a later retry
  recovers it.

## Response lifetime

`response_retention {count, unit}` defaults to `retention` and must be positive and no longer
than it. After the response deadline, maintenance removes the payload and records
`response_expired_at` while preserving the claim through its retention deadline. A held
response never expires. A matching retry returns `:response_expired` (410); a different
fingerprint still returns `:key_reused_with_different_request`. Neither calls the peer, and a
cached response cannot extend the response deadline. Cleanup eventually removes a completed,
unheld claim and cascades its outcome rows.

## Holds after external completion

An idempotency protection's `hold` callback also runs when an external effect completes.
The hold and response become authoritative together in the local completing transaction;
a processing recovery point cannot carry a hold. The caller must release an open operation's
reference in its settling transaction. See
[Idempotency](idempotency.md#keep-an-open-operations-record) for reference uniqueness,
retention after release, row security, and the race with an uncommitted completion.
