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

Adapters must make execute idempotent by operation key and make recover authoritative. A
stub that merely records the request proves only that the package produced a shape; peer
conformance requires a live peer contract. External effects are idempotency-only because a
nonce cannot safely recover or replay a response.
