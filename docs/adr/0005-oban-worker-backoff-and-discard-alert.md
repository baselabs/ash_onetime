# ADR 0005: Oban worker backoff and discard alerts

Maintenance workers use three attempts with linear jittered retry delay:
`min(30 * attempt + :rand.uniform(30) - 1, 120)` seconds.
The first two waits are 30–59 and 60–89 seconds, spacing contended DDL retries.
Invalid arguments discard immediately; Store failures keep their typed inner reason in
`{:error, {:cleanup_failed | :reap_failed | :roll_partitions_failed, reason}}`.

Cleanup, reap, and partition creation use separate queues: `ash_onetime_cleanup`,
`ash_onetime_reap`, and `ash_onetime_partitions`. Consumers must configure each queue they use.
Monitor discarded jobs on those queues; a discarded roll requires repair with
`mix ash_onetime.roll_partitions --repo MyApp.Repo` and investigation of contention.
Claim cleanup enforces retention; rolling and pruning keep monthly storage manageable.
See [Operations](../../documentation/operations.md) for discard queries and pool triage.
