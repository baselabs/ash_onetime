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
the same logical key is a new execution with a new peer operation key, so the peer — not the
package — is the last line of defense against a duplicate effect for a claim abandoned that long.

Adapters must make execute idempotent by operation key and make recover authoritative. A
stub that merely records the request proves only that the package produced a shape; peer
conformance requires a live peer contract. External effects are idempotency-only because a
nonce cannot safely recover or replay a response.

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
2. **The peer MUST enforce idempotency by operation key** so a redundant execute is absorbed.

The package supplies the operation key (the authoritative committed claim UUID) to both
callbacks; the adapter passes it unchanged to the peer's idempotency and recovery surfaces.
The combination of (1) and (2) is what makes external effects safe: the package's `:absent`
trust is correct because a correct adapter proves absence, and a correct peer deduplicates
the redundant execute that a lying adapter would induce. Remove either defense and the
guarantee degrades to the honesty of whichever remains.
