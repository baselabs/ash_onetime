# ADR 0010: Pre-peer claim lock for external effects

Before any peer call, lock the full claim row in the caller's transaction, including its UUID
and logical key. Re-resolve after waiting: processing proceeds, complete replays, and a missing
or reaped-and-reinserted generation fails closed. Same-key retries serialize at the committed
claim worker and again at the caller-side lock.

`external_lock_timeout_ms` defaults to 2,000 ms and accepts 1..25,000 ms, below the worker's
30-second kill. The same bound applies to finalization's claim load and individually to external
completion writes. A lock timeout returns `:request_in_progress` and aborts that transaction.
Capture and restore the prior lock_timeout around each bounded statement; do not cap adapter
writes or network callbacks. A failed, aborted transaction cannot restore its setting.

The peer must enforce operation-key idempotency even for sequential retries; atomic key claims
are recommended. Never run two same-key external actions inside one transaction: the second
worker waits on the first action's connection. Callbacks retain the transaction contract in ADR 0011.
