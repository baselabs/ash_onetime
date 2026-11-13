# Idempotency

Idempotency means once-per-key execution with stored-result replay. It is for safe retries,
not for rejecting a captured request.

The logical admission identity is derived from the protected resource and action, explicit
scope components, and key components. A separate fingerprint binds request content. The
caller cannot override the operation hash. Reusing a key with a different fingerprint is
terminal and never executes again.

For local effects, PostgreSQL claims admission inside the Ash action's existing transaction.
The unique constraint decides concurrent races; there is no admission pre-read. The effect,
claim, encoded response, and response digest commit or roll back together. A completed retry
loads authoritative claim metadata and bytes, validates codec, digest, fingerprint, and
locator identity, then reconstructs the declared Ash return type without running the action,
notifications, or unsafe lifecycle hooks again.

Actions with the same key remain independent when their resource/action identity differs.
Actions with the same operation and key remain independent when their explicit scope differs.
Natural attribute keys and client-supplied keys have the same database race semantics.

## Failure direction

All sent, rolled-back, disconnected, or ambiguous admission outcomes fail closed. The only
optional untracked path is a checkout failure classified as never dispatched and not
applicable to a transaction. It requires explicit
`on_definite_store_failure :execute_untracked` and emits
`[:ash_onetime, :untracked_execution]`. This exception is retry-safe idempotency behavior;
it is structurally unavailable to one-time nonces.

An optional cache can replace authoritative response payload bytes only after PostgreSQL has
returned a complete claim and every cached identity and digest field matches. A cache miss,
timeout, circuit-open result, corrupt value, or stale entry falls back to authoritative bytes;
the cache never admits an effect.

Do not describe this as exactly-once delivery. The guarantee is a PostgreSQL-authoritative,
once-per-key local effect and typed replay within the declared retention boundary.

## Keep an open operation's record

A request can finish while the operation it opened continues. Set a hold at completion so
retries keep replaying the same record, even after its `retain_until` has passed. No cleanup,
reap, or DEFAULT drain deletes a held claim, and payload-partition pruning keeps any month
holding its response bytes. Nonce claims have no hold surface.

For transaction-owned admission:

```elixir
:ok = AshOnetime.Transaction.complete(admission, response_bytes, hold: operation_reference)
```

For an Ash action, implement `AshOnetime.Hold` and declare `hold MyApp.OperationHold` inside
its idempotency `protect` block:

```elixir
defmodule MyApp.OperationHold do
  @behaviour AshOnetime.Hold

  @impl true
  def reference(result, _context) do
    if result.status == :open, do: {:hold, result.operation_reference}, else: :none
  end
end
```

The callback receives the original action result and `%{resource: resource, action: action}`
inside completion. Return `:none` when the outcome is already settled in that action. A hold
and completion are written atomically, in the completing transaction, for both database and
external modes. Database-mode admission remains inside the action's transaction; action writes,
claim, payload, completion, and hold commit or roll back together. A replay does not call the
hold module or extend retention.

References are caller-chosen, valid UTF-8 binaries of 1..255 bytes without NUL. They must be
unique within the installation's logical partition; a UUID meets this requirement. Several
claims for the same operation may share a reference and are released together. Invalid
references or callback outcomes return typed `:invalid_request` errors.

**The caller must release the hold in the operation's settling transaction.** For the
transaction API, supply the exact installation and logical partition:

```elixir
{:ok, released_count} = AshOnetime.Transaction.release(MyApp.Repo,
  partition: logical_partition,
  prefix: schema_prefix,
  reference: operation_reference
)
```

`release/2` never begins or commits a transaction and requires READ COMMITTED. Unknown
references return `{:ok, 0}`. A rollback of the settling transaction leaves the hold in place.
Release clears the reference and sets
`retain_until = GREATEST(retain_until, statement_timestamp() + (retain_until - admitted_at))`:
the normal retention window counted from release, never a shorter deadline.

An Ash settling create, update, or destroy action can declare:

```elixir
change {AshOnetime.Changes.ReleaseHold, reference: :operation_reference}
# When the protected resource differs from the settling resource:
change {AshOnetime.Changes.ReleaseHold,
  reference: & &1.operation_reference, resource: MyApp.ProtectedOperation}
```

The reference comes from the action's result record. The change addresses the installation
exactly as protection admission does: from the protected resource (default: the settling
resource), the settling changeset's tenant, and its data-layer context. It accepts
no separate partition string: DSL protections use the installation's default logical partition.
The settling action must run transactionally. Update actions using the change must set
`require_atomic? false` to run Ash's transactional action hooks. Release always runs as the caller's role and
only releases rows visible under its row security; it never uses SECURITY DEFINER or bypasses
policies.

A settling action on another connection cannot release an uncommitted hold. Coordinate the
operation's lifecycle so settling happens after admission commits; a zero release count does
not establish that no operation is still committing. If a caller never releases, the records
are kept forever by design. Watch `AshOnetime.Store.held_backlog(target)` and the live doctor.

### Database guard boundary

The BEFORE DELETE guard refuses held claims with SQLSTATE `23514`, including DELETEs by the
table owner and a superuser, before checking retention or payload cardinality. Cleanup and the
DEFAULT drain exclude held rows before invoking it; reap selects processing rows only.

Like the existing retention guard, this is a DELETE trigger: it does **not** stop `TRUNCATE`,
`DROP`, a privileged user disabling the trigger, or a superuser setting
`session_replication_role = replica`. These operations bypass its protection. Holds are a
PostgreSQL-authoritative application invariant within that boundary, not protection against
administrative destruction.
