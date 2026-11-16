# ADR 0003: Independent-commit nonce

Nonce protections default to `commit: :with_action`: a body failure rolls back the spend.
Opt-in `commit: :independent` commits the burn marker before the body on a separate connection,
so body failure cannot make the same proof admissible again. It supports request-attempt
replay fencing such as DPoP. The option is refused for idempotency.

The marker has no response payload or replay path. A collision returns `:nonce_already_used`.
Cleanup cannot remove it within its retention window; every store failure fails closed.

Budget one additional pool connection per in-flight independent admission. The worker timeout
is 30 seconds. `:worker_timeout`, `:lock_timeout`, `:disconnected`, and unknown dispatch remain
distinct uncertainty classes; exceptions expose only their module atom through diagnosis events.
The idempotency-only untracked-execution branch is unreachable for nonce admission.
