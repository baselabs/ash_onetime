# ADR 0002: Abandoned processing-claim reaper

The opt-in reaper bounds abandoned idempotency recovery points; nonce claims are unaffected.
A processing claim is deletable only after its retention deadline and after both the requested
abandonment horizon and the hard one-day floor. The delete guard rechecks those conditions.

Reap uses database time and a bounded `FOR UPDATE SKIP LOCKED` batch. Its transaction-local
cutoff authorizes only that guarded deletion. Cleanup continues to skip processing claims.

Locality is fixed at insertion. Only local processing claims are eligible: external claims
and unclassified claims admitted by a historical runtime are excluded by both selection and
the DELETE guard. Reap preserves their UUIDs and per-attempt outcomes, regardless of age.
External recovery points remain until authoritative recovery completes them.

Schedule reap explicitly and size the horizon beyond legitimate in-flight work. It bounds
steady-state growth only when scheduled; edge rate limits control admission bursts.
