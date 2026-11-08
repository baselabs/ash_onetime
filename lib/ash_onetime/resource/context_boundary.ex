defmodule AshOnetime.Resource.ContextBoundary do
  @moduledoc """
  The normalized context-boundary declaration produced by the `context_boundary` section.

  A resource that declares `context_boundary` opts into conditional-append semantics backed
  by the named append-only fact table. `AshOnetime.Boundary.read/3` returns the facts a
  query matches plus the cutoff they were read at, and
  `AshOnetime.Boundary.append_if/5` appends new facts only when no fact matching the same
  query has a `seq` above that cutoff. Read the declaration back with
  `AshOnetime.Resource.Info.context_boundary/1`.
  """

  defstruct [:fact_table, :__spark_metadata__]

  @type t :: %__MODULE__{
          fact_table: binary(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta() | nil
        }

  # Identifier ceiling leaves room for the generated index and trigger name
  # suffixes (PostgreSQL truncates identifiers past 63 bytes, which would let
  # two long table names collide on their `_tags` index).
  @max_fact_table_bytes 48

  @doc """
  Validates a fact-table name: a lowercase SQL identifier of at most
  #{@max_fact_table_bytes} bytes (letters, digits, underscore, starting with a letter)
  without the reserved `ash_onetime_` prefix. The DSL section's transformer and the
  migration generator both call this, so the two cannot drift.
  """
  def validate_fact_table(name) when is_binary(name) do
    cond do
      byte_size(name) not in 1..@max_fact_table_bytes ->
        {:error, invalid_name_message()}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error, invalid_name_message()}

      String.starts_with?(name, "ash_onetime_") ->
        {:error, "fact_table must not use the reserved \"ash_onetime_\" prefix"}

      true ->
        {:ok, name}
    end
  end

  def validate_fact_table(_name), do: {:error, invalid_name_message()}

  defp invalid_name_message do
    "fact_table must be a lowercase SQL identifier of at most #{@max_fact_table_bytes} bytes " <>
      "(letters, digits, underscore) starting with a letter"
  end
end
