defmodule AshOnetime do
  @moduledoc """
  Explicit keyed-effect semantics for Ash actions.

  `ash_onetime` separates replay-safe idempotency from collision-rejecting one-time
  nonces. Protected actions must declare a strategy and an explicit scope.
  """

  @doc """
  Reports whether a protected-action result was a stored replay or a fresh execution.

  Returns:

    * `true` — the result was a **tracked replay**: a stored response was returned without
      re-executing the effect (map to HTTP `200` with an `Idempotent-Replayed` header, or
      suppress a duplicate side effect).
    * `false` — the result was a **tracked fresh execution**: the effect ran and its
      response was stored (map to HTTP `201`).
    * `nil` — the carrier is absent. This covers three cases the caller cannot distinguish
      by this signal alone: an **untracked** execution (which intentionally carries no
      `ash_onetime` metadata, per ADR 0001's untracked-transparency goal), a
      **primitive-return** action whose result is not a record (e.g. a generic action
      returning an integer), or a result that was never protected by `ash_onetime`.

  For record-returning actions (create/update, generic actions returning a struct, destroy
  with `return_destroyed?`), the signal is `true`/`false`. For primitive returns and
  untracked executions it is `nil` — use a record-returning action, or observe replay inside
  the action via an `after_action` hook reading the admission state, if you need replay
  observability on a primitive return. See `documentation/replay.md`.
  """
  @spec replayed?(term()) :: boolean() | nil
  def replayed?(%{__metadata__: metadata}) when is_map(metadata) do
    case metadata do
      %{ash_onetime: %{replayed: replayed}} when is_boolean(replayed) -> replayed
      _other -> nil
    end
  end

  def replayed?(_other), do: nil

  @doc """
  Runs a protected action that declares `executing_only` values and delivers those values
  to this caller, at most once.

  `subject` is one changeset or action input already built for that action
  (`Ash.Changeset.for_create/4`, `for_update/4`, `for_destroy/4`,
  `Ash.ActionInput.for_action/4`). `opts` are the options of `Ash.create/2`,
  `Ash.update/2`, `Ash.destroy/2` or `Ash.run_action/2`. An update runs with
  `atomic_upgrade?: false`.

  Returns:

    * `{:ok, result, %AshOnetime.Delivery{}}`, or
      `{:ok, result, notifications, %AshOnetime.Delivery{}}` when Ash returns
      notifications. `result` is `nil` where Ash returns `:ok` (a generic action without a
      return type; a destroy without `return_destroyed?`).
    * `{:error, error}` with no values.

  The `AshOnetime.Delivery` outcome is `:executed` with every declared value,
  `:replayed` or `:recovered` with none. Only this caller can open the values: they are
  sealed when the producer returns them, to a key that exists only inside this call.

  Refused with `:executing_only_refused` before anything runs: a bulk subject, a subject
  not built for its action, or a call Ash would run in another process. Any doubt after
  the action ran returns `:executing_only_lost` with no value; a value lost after commit
  is lost for good (revoke and reissue).
  """
  @spec deliver(Ash.Changeset.t() | Ash.ActionInput.t(), keyword()) ::
          {:ok, term(), AshOnetime.Delivery.t()}
          | {:ok, term(), [Ash.Notifier.Notification.t()], AshOnetime.Delivery.t()}
          | {:error, term()}
  def deliver(subject, opts \\ []), do: AshOnetime.Delivery.deliver(subject, opts)

  @doc """
  The reserved verification-input names a protected action must never accept from caller
  input — `:key`, `:issued_at`, `:expires_at`, `:verification_state`, `:algorithm`. These
  are trusted local facts the verification path derives itself; accepting them as action
  arguments, accepted attributes, or declared attributes would let caller input supply
  pre-verified facts (AGENTS.md: "verification callbacks return trusted local facts;
  action input cannot supply pre-verified facts").

  Single source for the compile-time transformer check (`Resource.Transformer`) and the
  runtime guard (`Admission.reject_reserved/1`) so the two cannot drift.
  """
  def reserved_verification_inputs,
    do: [:key, :issued_at, :expires_at, :verification_state, :algorithm]
end
