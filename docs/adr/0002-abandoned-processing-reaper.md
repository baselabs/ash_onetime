# ADR 0002: Abandoned processing-claim reaper

The opt-in reaper bounds abandoned idempotency recovery points; nonce claims are unaffected.
A processing claim is deletable only after its retention deadline and after both the requested
abandonment horizon and the hard one-day floor. The delete guard rechecks those conditions.

Reap uses database time and a bounded `FOR UPDATE SKIP LOCKED` batch. Its transaction-local
cutoff authorizes only that guarded deletion. Cleanup continues to skip processing claims.

A reaped claim loses its UUID and therefore its external operation key. A later retry is a
new execution under a new key; neither the library nor peer key deduplication can recognize
the lost execution. External actions require business reconciliation before abandonment.

Schedule reap explicitly and size the horizon beyond legitimate in-flight work. It bounds
steady-state growth only when scheduled; edge rate limits control admission bursts.
