defmodule AshOnetime.Changes.ReleaseHold do
  @moduledoc """
  Releases operation holds inside an Ash settling action's transaction.

      change {AshOnetime.Changes.ReleaseHold, reference: :operation_reference}
      change {AshOnetime.Changes.ReleaseHold,
              reference: & &1.operation_reference, resource: ProtectedResource}

  `:reference` is an attribute name or a one-argument function of the action's result record.
  Optional `:resource` names the protected resource whose installation to address; it defaults
  to the settling resource. The repo, prefix, and default logical partition are derived with
  `Postgres.target(resource, options)`, using the settling changeset's tenant and data-layer
  context, exactly as protection admission does. There is no partition-string option.

  The action must run in a READ COMMITTED transaction. Release runs as the caller's role,
  obeys row security, and commits or rolls back with the settling action. References must
  be unique within the installation's logical partition (a UUID meets this requirement).
  Update actions using this change must set `require_atomic? false` so Ash runs their
  transactional action hooks.
  """

  use Ash.Resource.Change

  alias AshOnetime.Error
  alias AshOnetime.Store.{Postgres, Result}

  @impl true
  def init(options) do
    if valid_options?(options) and valid_source?(options[:reference]) and
         valid_resource?(options) do
      {:ok, options}
    else
      {:error,
       "ReleaseHold requires reference: attribute_or_function and optional resource: module"}
    end
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and
      length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
      Enum.all?(Keyword.keys(options), &(&1 in [:reference, :resource]))
  end

  defp valid_source?(source),
    do: (is_atom(source) and not is_nil(source)) or is_function(source, 1)

  defp valid_resource?(options),
    do:
      not Keyword.has_key?(options, :resource) or
        (is_atom(options[:resource]) and not is_nil(options[:resource]))

  @impl true
  def change(changeset, options, _context) do
    Ash.Changeset.after_action(changeset, fn pending, record ->
      with {:ok, target} <- target(pending, options),
           {:ok, reference} <- reference(record, options[:reference]),
           {:ok, _count} <- release(target, reference) do
        {:ok, record}
      end
    end)
  end

  @impl true
  def batch_change(changesets, options, context),
    do: Enum.map(changesets, &change(&1, options, context))

  @impl true
  def atomic(_changeset, _options, _context),
    do: {:not_atomic, "hold release requires transactional execution"}

  defp target(changeset, options) do
    case Postgres.target(options[:resource] || changeset.resource,
           data_layer_context: get_in(changeset.context, [:data_layer]),
           tenant: changeset.to_tenant
         ) do
      {:ok, target} -> {:ok, target}
      %Result{reason: reason} -> {:error, Error.new(reason, "hold release target is unavailable")}
    end
  end

  defp release(target, reference) do
    case Postgres.release(target, reference) do
      {:ok, count} -> {:ok, count}
      %Result{reason: reason} -> {:error, Error.new(reason, "hold release failed")}
    end
  end

  defp reference(record, source) do
    reference = if is_function(source, 1), do: source.(record), else: Map.get(record, source)
    with :ok <- AshOnetime.Hold.validate_reference(reference), do: {:ok, reference}
  rescue
    _exception -> {:error, Error.new(:invalid_request, "hold release reference is invalid")}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_request, "hold release reference is invalid")}
  end
end
