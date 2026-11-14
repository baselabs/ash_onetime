# 12. Monitored-worker callback bounding

Date: 2026-11-13

## Status

Accepted.

## Context

Custody, verifiers and minters are trusted external callbacks that do not share the
caller's transaction. A linked task allowed a killed worker to kill its caller; trapping
exits also exposed an unhandled task exit result. A failure in cryptographic custody must
remain distinguishable from a rejected proof without exporting custody diagnostics.

## Decision

The application starts a `Task.Supervisor`. All three callback kinds use one runner with
`Task.Supervisor.async_nolink`: supervised, monitored and unlinked to the caller. Its
deadline defaults to 5,000 ms and cannot exceed 30,000 ms. The application setting
`:callback_timeout_ms` sets the default; a protection's `limits: [verifier_timeout_ms: n]`
sets its verifier/minter deadline. Invalid runtime deadlines use the default; excessive
positive values are capped at the ceiling.

At the deadline the runner calls `Task.shutdown(task, :brutal_kill)` and flushes the task's
reply and monitor messages. A reply racing shutdown still counts as a deadline overrun.
Raises, throws, exits and DOWN messages of any reason become a contract violation.
A supervised owner-monitor task watches each worker and its waiting caller. It kills the
worker if the caller dies and exits when the worker ends. Elixir's task startup monitor
ends before callback execution; without this lifetime monitor, a killed verifier can
strand its nested custody worker. The callback itself still runs in one unlinked worker.

Callback result normalization stays at each boundary: custody uses its closed atom
vocabulary; verifiers and minters preserve only the documented typed-error allowlist,
with fixed package messages and empty details. Other explicit verification refusals remain
`:verification_failed`; malformed successful results become `:verifier_contract_violation`.

Custody implementations must not depend on the caller's process dictionary or transaction.
HMAC verification stays at the key holder. Verify-only clients need no signing permission.
The package validates shape and signature lengths, but custody is trusted cryptographic
code: the conformance suite cannot prove that a remote comparison is constant-time or
prevent a dishonest implementation from returning `:ok`.

## Consequences

The OTP application must be started before token signing or verification. External holders
can retain keys in their own processes; the token API never requests raw key material.
The token wire format and primitives remain unchanged (ADR-0008).

ADR-0011 is unchanged. Effect callbacks `execute/3` and `recover/3` still run in the caller's
transaction and must bound their own peer calls; moving them to this worker would break
their transactional contract.
