defmodule AshOnetime.Error do
  @moduledoc """
  Typed failure returned by AshOnetime boundary modules.
  """

  @enforce_keys [:code, :message]
  defexception [:code, :message, details: %{}]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          details: map()
        }

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
