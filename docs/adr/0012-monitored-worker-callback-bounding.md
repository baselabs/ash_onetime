# ADR 0012: Monitored-worker callback bounding

Custody, verifier, and minter callbacks use supervised, monitored, unlinked workers.
The application must be started before signing or verification. These callbacks must not
depend on the caller's process dictionary or transaction.

The deadline defaults to 5,000 ms and caps at 30,000 ms. `:callback_timeout_ms` sets the
default; protection `limits: [verifier_timeout_ms: n]` sets verifier/minter deadlines.
Invalid runtime values use the default; excessive positive values cap at the ceiling.

At deadline, kill the task and flush reply/monitor messages; a shutdown-racing reply is late.
A lifetime monitor kills workers whose waiting caller dies, including nested custody work.
Raises, throws, exits, and DOWN reasons become sanitized contract violations.

Custody returns its closed atom vocabulary. Verifiers/minters preserve only documented typed
errors, with fixed package messages and empty details; other refusals become verification_failed
and malformed success becomes verifier_contract_violation. Keys stay at the holder; verify-only
clients need no signing permission. Conformance cannot prove an external holder's honesty or
constant-time comparison. External-effect callbacks retain ADR 0011's transaction semantics.
