defmodule AshOnetime.Hold do
  @moduledoc """
  Chooses whether a completed idempotent action retains its claim for an open operation.

  Declare `hold MyHold` on an idempotency protection. `reference/2` receives the action's
  result and a bounded `%{resource: resource, action: action}` context, inside the completing
  transaction. Return `{:hold, reference}` for an open operation or `:none` for a settled
  outcome. References must be valid UTF-8, 1..255 bytes, without NUL bytes, and unique within
  the installation's logical partition; a UUID meets this requirement.

  The caller must release the hold in the operation's settling transaction using
  `AshOnetime.Transaction.release/2` or `AshOnetime.Changes.ReleaseHold`. An unreleased hold
  keeps the claim forever by design. Monitor `AshOnetime.Store.held_backlog(target)` and the doctor.
  """

  alias AshOnetime.Error

  @doc "Returns a caller-chosen reference for an open operation, or `:none` when settled."
  @callback reference(result :: term(), context :: map()) :: {:hold, binary()} | :none

  @doc false
  @spec validate_reference(term()) :: :ok | {:error, Error.t()}
  def validate_reference(reference) when is_binary(reference) do
    if byte_size(reference) in 1..255 and String.valid?(reference) and
         not String.contains?(reference, <<0>>) do
      :ok
    else
      invalid_reference()
    end
  end

  def validate_reference(_reference), do: invalid_reference()

  defp invalid_reference,
    do:
      {:error,
       Error.new(
         :invalid_request,
         "hold reference must be a valid 1..255-byte UTF-8 binary without NUL"
       )}
end
