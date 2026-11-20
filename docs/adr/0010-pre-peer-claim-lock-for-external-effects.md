# ADR 0010: Pre-peer claim lock for external effects

Before any peer call, a committed worker grants an attempt under FOR UPDATE. The caller locks
the full claim row FOR NO KEY UPDATE, including its UUID and logical key, and classifies that
attempt again after waiting. Only its granted processing attempt proceeds; complete replays,
and a stale attempt or replaced generation fails closed. Finalization and replay loads use
FOR NO KEY UPDATE too. Same-key callers still serialize at the worker and caller locks.

`external_lock_timeout_ms` defaults to 2,000 ms and accepts 1..25,000 ms, below the worker's
30-second kill. The same bound applies to finalization's claim load and individually to external
completion writes. A lock timeout returns `:request_in_progress` and aborts that transaction.
Capture and restore the prior lock_timeout around each bounded statement. Adapter writes,
network callbacks, local claims and hold release keep their ambient bounds. A failed,
aborted transaction cannot restore its setting.

An independent worker records an unproven result against its granted attempt. Its outcome
FK takes compatible FOR KEY SHARE, so it can commit beside a caller's claim lock. The
outcome insert has the same armed timeout and a worker deadline five seconds later.
Missing outcomes remain unresolved and never authorize reap. Parent deletion cascades the
outcomes; a late insert after deletion fails closed.

Inside-statement package helpers inherit the armed timeout and carry no timeout setting.
Consumer policy code can add waits; bounded failures become request_in_progress or
outcome_unrecorded with the claim retained. A policy function that changes a timeout is
outside those bounds. The full lock and authority inventories are in
[ADR 0014](0014-durable-external-claims.md).

The peer must enforce operation-key idempotency even for sequential retries; atomic key claims
are recommended. Never run two same-key external actions inside one transaction: the second
worker waits on the first action's connection. Callbacks retain the transaction contract in ADR 0011.
