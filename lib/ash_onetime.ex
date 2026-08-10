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
