defmodule AshOnetime.Store.Result do
  @moduledoc false

  alias AshOnetime.Store.Claim

  @enforce_keys [:status, :admission_dispatch, :transaction]
  defstruct [:status, :claim, :payload, :reason, :admission_dispatch, :transaction]

  @type status :: :admitted | :collision | :processing | :complete | :failure
  @type reason ::
          :invalid_request
          | :invalid_nonce_window
          | :not_in_transaction
          | :unsupported_isolation
          | :checkout_unavailable
          | :missing_prefix
          | :lock_timeout
          | :disconnected
          | :dispatched_unknown
          | :rolled_back
          | :corrupt_payload
          | :store_invariant

  @type t :: %__MODULE__{
          status: status(),
          claim: Claim.t() | nil,
          payload: binary() | nil,
          reason: reason() | nil,
          admission_dispatch: :not_started | :sent | :unknown,
          transaction: :open | :rolled_back | :unknown | :not_applicable
        }

  @spec success(status(), keyword()) :: t()
  def success(status, fields \\ [])
      when status in [:admitted, :collision, :processing, :complete] do
    struct!(
      __MODULE__,
      [status: status, admission_dispatch: :sent, transaction: :open] ++ fields
    )
  end

  @spec failure(
          reason(),
          :not_started | :sent | :unknown,
          :open | :rolled_back | :unknown | :not_applicable
        ) ::
          t()
  def failure(reason, dispatch, transaction) do
    %__MODULE__{
      status: :failure,
      reason: reason,
      admission_dispatch: dispatch,
      transaction: transaction
    }
  end
end
