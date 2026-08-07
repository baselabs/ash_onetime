# Replay: fresh execution vs stored replay

The most common reason to adopt an idempotency library is a Stripe-style HTTP layer: return
**201** (Created) on first execution and **200** with `Idempotent-Replayed: true` on retry,
or suppress a duplicate confirmation email on the retry. `ash_onetime` exposes this signal
on the result so the outer caller can observe it after `Ash.create/2` / `Ash.run_action/2`
returns.

## `AshOnetime.replayed?/1`

```elixir
case Ash.create(changeset) do
  {:ok, record} ->
    case AshOnetime.replayed?(record) do
      false -> send_resp(conn, 201, encode(record))   # fresh execution
      true  -> send_resp(conn, 200, encode(record))   # stored replay
      nil   -> send_resp(conn, 201, encode(record))   # cannot tell (see below)
    end

  {:error, error} -> handle_error(error)
end
```

The signal is **tri-state**:

| Returns | Means |
|---|---|
| `true` | **Tracked replay.** A stored response was returned without re-executing the effect. Map to HTTP `200` (+ `Idempotent-Replayed` header), or suppress a duplicate side effect. |
| `false` | **Tracked fresh execution.** The effect ran and its response was stored. Map to HTTP `201`. |
| `nil` | **Carrier absent.** The signal cannot be observed for this result. See below. |

### When `nil` is returned

`nil` covers three cases the signal cannot distinguish — by design:

1. **An untracked execution** — when `on_definite_store_failure: :execute_untracked` is set
   and the store was provably never contacted, the action runs without admission. An
   untracked execution must stay observationally indistinguishable from an unprotected
   action (ADR 0001), so it carries no `ash_onetime` metadata and `replayed?/1` returns
   `nil`.
2. **A primitive-return action** — a generic action returning an integer, string, or atom
   (not a record) has no `__metadata__` slot, so the signal cannot attach. `replayed?/1`
   returns `nil` on both the fresh and the replayed primitive return.
3. **A result that was never protected** by `ash_onetime`.

For the primitive-return case, use a record-returning action, or observe replay inside the
action via an `after_action` hook that reads the in-flight admission state:

```elixir
Resource
|> Ash.ActionInput.for_action(:redeem, arguments)
|> Ash.ActionInput.after_action(fn input, result ->
  # The admission module exposes a replay predicate for in-action use; it reads the
  # in-flight input the outer caller never holds. Use it to suppress a duplicate side
  # effect on a replay.
  if AshOnetime.Admission.replay?(input), do: suppress_side_effect()
  {:ok, result}
end)
|> Ash.run_action()
```

The admission module's replay predicate takes the in-flight input the caller no longer
holds, so it is for in-action use only (the admission module is `@moduledoc false`; reach
for it only when you cannot use a record-returning action).

## The carrier

The signal lives on the result's metadata: `record.__metadata__[:ash_onetime][:replayed]`.
It is stamped by `ash_onetime` at the protected-action boundary for tracked admission
classes (`:execute`, `:external_execute`, `:replay`, `:nonce`); it is **not** stamped for
`:untracked` (transparency) or for non-record results (no carrier).

The metadata is ephemeral — it is never persisted. A result read back from the database
later does not carry it; the signal describes only the action call that produced the record.
