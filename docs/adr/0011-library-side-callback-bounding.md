# ADR 0011: External-effect callbacks retain the caller transaction

`execute/3` and `recover/3` run synchronously inside the caller's open PostgreSQL transaction.
The library imposes no wall-clock timeout on these callbacks. Moving them to another process
would break same-transaction adapter writes, including transactional outbox rows.

Adapters must bound their own peer calls. Ambiguous execute immediately invokes recover in
the same request and transaction, so budget for both waits and the checked-out connection.
Claim-lock and completion-statement bounds apply only to package statements (ADR 0010),
not to adapter SQL or peer calls.
