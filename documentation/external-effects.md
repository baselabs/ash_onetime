# External effects and recovery

An external peer cannot share the local PostgreSQL transaction. Protected external effects
therefore use a committed recovery point plus a peer operation key instead of pretending the
two systems commit atomically.

The adapter implements the ExternalEffect execute and recover callbacks. Both receive
the authoritative claim UUID as the operation key and must pass it unchanged to the peer's
idempotency and recovery surfaces.

1. PostgreSQL commits a claim in `processing` before any peer call.
2. A fresh request calls `execute(operation_key, subject, context)`.
3. A retry of a processing claim calls `recover/3` first.
4. `{:ok, result}` is finalized locally while the claim is locked.
5. `:absent` is proof that execution never happened; only then may the same operation key be
   executed.
6. `:unknown`, an exception, malformed output, disconnection, or timeout remains ambiguous.
   It never permits a second execute or local finalization.

If the caller dies before peer execution, recovery can prove absence and execute once. If it
dies after peer success, recovery returns the existing peer result and local finalization
continues without a second peer effect. If local finalization rolls back, the processing
claim remains a recoverable point.

A processing claim that is never completed or recovered is retained for recovery, but not
forever: the opt-in reaper (`mix ash_onetime.reap`, see the operations guide) deletes it once
it is past both a long abandonment horizon and its own retention horizon. After that, a retry of
the same logical key is a new execution with a **new peer operation key**: the operation key is
the reaped claim's UUID, so the peer's key-based dedup cannot recognize the retry as the same
operation. For an abandoned external-effect claim no key-based defense remains at either layer —
the prior outcome is unknown by definition (that is why it was abandoned), and neither the
package nor the peer can disambiguate the retry. Enable the reaper on an external-effect action
only together with a business-level reconciliation path (a statement, a report, an export) that
can settle an outcome-unknown claim before its abandonment horizon passes.

Adapters must make execute idempotent by operation key and make recover authoritative. A
stub that merely records the request proves only that the package produced a shape; peer
conformance requires a live peer contract. External effects are idempotency-only because a
nonce cannot safely recover or replay a response.

## Concurrent retries can execute twice under one operation key (normative)

Between committing the claim and finalizing, the package holds no lock: the claim commits in
its own transaction (which releases every lock on return), the peer call runs unguarded, and
the claim row is locked again only at finalize. A retry that arrives while the original
request is inside that window recovers first — and because the peer has not committed the
effect yet, an **honest** `recover/3` returns `:absent` and the retry executes under the
**same operation key**. The retry's execute can land while the original's execute is still
in flight: no caller death, no lying adapter, and — when the two executes overlap — no lock
at the package that serializes them through the peer. Both behaviors are observed on a live
PostgreSQL in `test/ash_onetime/external_contention_test.exs`: "an in-flight retry
truthfully recovers absence and both callers execute under one operation key" (two executes,
one key), and "a retry's execute overlaps the original's in-flight execute and only the
atomic key claim absorbs it" (the retry's key-claim insert observed blocked by the
original's uncommitted key row via `pg_blocking_pids`).

This is why defense 2 below is shaped the way it is:

1. **The peer's key dedup MUST be atomic.** Claiming the key must be a single statement —
   `INSERT ... ON CONFLICT` / an upsert against the key store — never a check-then-act
   (SELECT, then INSERT) sequence. Overlapping same-key executes must race inside one
   atomic claim, where exactly one wins and the other returns the stored result; the
   blocking-observation test above is exactly the race a check-then-act peer loses.
2. **The peer SHOULD record the key on receipt, before processing the effect**, so the
   redundant execute is absorbed deterministically rather than racing the effect itself.

The package's own guarantee is unaffected: finalize takes the claim row lock, serializes the
two callers, and leaves one local effect and one stored response. The redundant *peer*
execute is precisely the case defense 2 exists to absorb — but only an atomic dedup absorbs
it; a check-then-act peer double-spends here with every party conforming to the contract as
previously written.

## The adapter execution environment (normative)

Both callbacks run **inside the caller's open PostgreSQL transaction** — the action's
transaction is open on the caller's connection while `execute/3` and `recover/3` run — and
the package applies **no timeout** to either callback. Observed per callback on a live
PostgreSQL in `test/ash_onetime/external_contention_test.exs`: "the adapter callbacks run
inside the caller's open transaction" (`execute/3`) and "recover runs inside the retry
caller's open transaction" (`recover/3`); an open transaction on a checked-out connection
holds that pooled connection and an idle-in-transaction backend for as long as the callback
runs.

An adapter MUST bound its own peer call (its own HTTP timeout, deadline, or circuit): an
unbounded callback holds a pooled connection and an idle-in-transaction backend for as long
as the peer stalls, and at finalize the claim row lock as well. Note that after an ambiguous
`execute/3` the package calls `recover/3` **immediately, in the same request and
transaction** — so a request that executes ambiguously holds the caller's transaction for up
to two adapter timeouts. The package's other external callbacks (verifiers, minters) are
time-bounded by the package; the effect callbacks are bounded by the adapter.

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
2. **The peer MUST enforce idempotency by operation key — atomically** (a single-statement
   claim of the key, not check-then-act) so a redundant execute is absorbed, including the
   concurrent same-key executes an honest in-flight retry produces (see the concurrency
   section above).

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

  # The peer MUST claim the key atomically on receipt (INSERT ... ON CONFLICT or the
  # peer's equivalent single-statement upsert) BEFORE processing the effect, so a
  # concurrent same-key execute is absorbed deterministically. A peer that cannot is
  # not a valid external-effect peer.
  defp req_post(operation_key, subject) do
    Req.post(peer_url(operation_key),
      json: effect_request(subject),
      receive_timeout: @receive_timeout,
      retry: false
    )
    |> map_response()
  end

  defp req_get(operation_key, subject) do
    Req.get(peer_url(operation_key),
      params: effect_request(subject),
      receive_timeout: @receive_timeout,
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
