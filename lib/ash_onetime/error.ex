defmodule AshOnetime.Error do
  @moduledoc """
  Typed failure returned by AshOnetime boundary modules.

  `AshOnetime.Error` is a [Splode](https://hexdocs.pm/splode) error of class `:invalid`,
  so Ash recognizes it and preserves it through the action pipeline instead of wrapping it
  as an unknown error. The typed `:code` therefore reaches the caller inside
  `Ash.Error.Invalid{errors: [%AshOnetime.Error{code: ...}]}`, where it can drive HTTP
  status mapping (`AshOnetime.Error.code/1`) — see `documentation/errors.md` for the
  code→HTTP table.
  """

  use Splode.Error, class: :invalid, fields: [:code, :message, :details]

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

  @doc """
  Returns the typed `:code` from an `AshOnetime.Error`, or the single leaf
  `AshOnetime.Error` inside an `Ash.Error.Invalid`/`Ash.Error.Unknown` class wrapper.

  Returns `nil` for any other value (including exceptions that are not `AshOnetime.Error`
  and class wrappers carrying no `AshOnetime.Error` leaf), so a caller can distinguish
  "ash_onetime rejected this with a known code" from "some other error occurred" without
  pattern-matching the wrapper shape.
  """
  @spec code(t() | Exception.t() | term()) :: atom() | nil
  def code(%__MODULE__{code: code}), do: code

  def code(%{errors: errors}) when is_list(errors) do
    case Enum.find(errors, &match?(%__MODULE__{}, &1)) do
      %__MODULE__{code: code} -> code
      nil -> nil
    end
  end

  def code(_other), do: nil

  @impl true
  def message(%__MODULE__{message: message}) do
    message
  end
end
