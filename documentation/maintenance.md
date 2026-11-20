# Maintenance and durable recovery points

PostgreSQL decides maintenance eligibility. Every installation has its own owner-owned
routine schema and declared maintenance role. The runtime role keeps request privileges;
maintenance receives no table ownership or general row-security bypass.

| Path | Eligible work | External processing claims |
|---|---|---|
| Reap | Abandoned, unheld local processing claims past retention and the abandonment horizon | Preserved, including legacy unknown rows and every per-attempt outcome |
| Response expiry | Completed, unheld responses past `response_retain_until`, with exactly one payload | Preserved |
| Cleanup | Completed, unheld claims past `retain_until`; deletes the response and cascades outcomes | Preserved |
| Prune | Expired monthly payload partitions proved empty under the owner | Preserved |
| Roll | Creates monthly coverage and relocates DEFAULT payloads atomically | Preserved |
| Ordered rollback | Locks the claim and outcome parents before its exact refusal count | Refuses unresolved external rows before removing protection |

Expiry deletes response bytes and clears the response locator in one transaction. Replay
returns a complete response or `:response_expired`, with fingerprint validation first. A hold
prevents response expiry and claim cleanup. Cleanup accepts an expired claim with no payload;
missing or duplicate payloads on an unexpired completed claim are corruption and refuse.

The reaper's step record includes `kept_external`. These recovery points deliberately have no
maintenance deletion horizon. Monitor their count and age, and recover them through the
application's authoritative peer recovery workflow. Never turn an ambiguous peer result into
a new operation UUID to clear a backlog.

Maintenance checks trusted relation shape, function identities, row-security policies and
effective table and column authority. Outcomes grant runtime `SELECT` and `INSERT` only;
the guard forbids updates and deletion while their parent exists. Trust refuses additional
writers or an altered visibility helper. Reference shapes reconstruct the complete foreign
key graph and normalize PostgreSQL's generated RI identities.

Maintenance table locks permit ordinary request DML. Response expiry skips locked claims;
cleanup and reap also skip candidates they cannot lock. Roll and prune can hold payload
partition locks, so external completion bounds its writes. Claim callers use `FOR NO KEY
UPDATE`; outcome inserts use the foreign key's compatible `FOR KEY SHARE`. Consumer policy
code can introduce additional waits. It inherits the armed timeout unless it changes a
timeout itself; see [security](security.md).

Use bounded batches and short transactions. See [operations](operations.md) for commands,
role setup, status and the live doctor, and [upgrading](upgrading.md) for the migration order.
