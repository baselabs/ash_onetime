defmodule AshOnetime.ExternalEffect do
  @moduledoc """
  Contract for a peer effect that is idempotent and recoverable by operation key.

  The first argument to both callbacks is the authoritative committed claim UUID.
  An adapter must pass it unchanged to the peer's idempotency and recovery surfaces.
  `:absent` is authoritative proof that no peer operation exists; every uncertain,
  exceptional, or malformed outcome is ambiguity and must not permit a new key.

  When the protection declares `executing_only` names, `execute/3` returns
  `{:ok, peer_result, values}`, where `values` is a map with exactly the declared names as
  keys, each a binary of at most 64 KiB. The package seals the map at once to the
  `AshOnetime.deliver/2` caller and never stores it; any other shape is an unknown outcome.
  `recover/3` never returns values: a recovered execution delivers none.
  """

  @private_result :ash_onetime_external_result
  @private_operation_key :ash_onetime_external_operation_key

  @type operation_key :: Ecto.UUID.t()
  @type subject :: Ash.Changeset.t() | Ash.ActionInput.t()
  @type peer_result :: term()
  @type trusted_context :: map()

  @callback execute(operation_key(), subject(), trusted_context()) ::
              {:ok, peer_result()}
              | {:ok, peer_result(), %{optional(atom()) => binary()}}
              | {:error, :outcome_unknown}

  @callback recover(operation_key(), subject(), trusted_context()) ::
              {:ok, peer_result()} | :absent | :unknown

  @spec result(subject()) :: {:ok, peer_result()} | :error
  def result(%{context: %{private: %{@private_result => result}}}), do: {:ok, result}
  def result(_subject), do: :error

  @spec operation_key(subject()) :: {:ok, operation_key()} | :error
  def operation_key(%{context: %{private: %{@private_operation_key => operation_key}}}),
    do: {:ok, operation_key}

  def operation_key(_subject), do: :error

  @doc false
  @spec put_result(subject(), operation_key(), peer_result()) :: subject()
  def put_result(%Ash.ActionInput{} = subject, operation_key, result),
    do:
      Ash.ActionInput.set_context(subject, %{
        private: %{@private_operation_key => operation_key, @private_result => result}
      })

  def put_result(%Ash.Changeset{} = subject, operation_key, result),
    do:
      Ash.Changeset.set_context(subject, %{
        private: %{@private_operation_key => operation_key, @private_result => result}
      })
end
