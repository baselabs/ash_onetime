defmodule AshOnetime.Boundary.Change do
  @moduledoc """
  Places a conditional context-boundary append on a create action.

  The query, cutoff, facts, and tenant are resolved from literal options and
  `{:argument, name}` / `{:attribute, name}` references — action input carries the
  caller's read results, and the append itself runs in the action's transaction via
  `AshOnetime.Boundary.append_if/5`. A changed context fails the action with a typed
  `:context_changed` error carrying the seq that moved; admitted seqs are stamped into
  the record's metadata under `:ash_onetime_boundary`.

      change {AshOnetime.Boundary.Change,
              query: {:all, [tag: {:argument, :context_tag}, type: "refund"]},
              cutoff: {:argument, :context_cutoff},
              facts: {:argument, :context_facts}}
  """

  use Ash.Resource.Change

  alias AshOnetime.{Boundary, Error}

  @impl true
  def init(opts) do
    with :ok <- query_shape(opts[:query]),
         :ok <- reference_shape(opts[:cutoff]),
         :ok <- reference_shape(opts[:facts]),
         :ok <- tenant_shape(opts[:tenant]) do
      {:ok, opts}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> Ash.Changeset.before_action(
      fn pending -> append(pending, opts) end,
      prepend?: true
    )
    |> Ash.Changeset.after_action(
      fn pending, result -> stamp_metadata(pending, result) end,
      prepend?: true
    )
  end

  @impl true
  def batch_change(changesets, opts, context),
    do: Enum.map(changesets, &change(&1, opts, context))

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "context boundary appends require transactional execution"}

  defp append(changeset, opts) do
    with {:ok, query} <- resolve_query(opts[:query], changeset),
         {:ok, cutoff} <- resolve_reference(opts[:cutoff], changeset),
         {:ok, facts} <- resolve_reference(opts[:facts], changeset),
         {:ok, tenant} <- resolve_tenant(opts[:tenant], changeset) do
      case Boundary.append_if(changeset.resource, query, cutoff, facts, tenant: tenant) do
        {:ok, appended} ->
          Ash.Changeset.put_context(changeset, :ash_onetime_boundary, %{
            seqs: Enum.map(appended, & &1.seq)
          })

        {:error, {:context_changed, max_seq}} ->
          {:error, Error.new(:context_changed, "context changed since read", %{max_seq: max_seq})}

        {:error, %Error{}} = error ->
          error
      end
    else
      {:error, %Error{}} = error -> error
    end
  end

  defp stamp_metadata(changeset, result) do
    case changeset.context[:ash_onetime_boundary] do
      %{seqs: seqs} when is_list(seqs) ->
        {:ok, Ash.Resource.put_metadata(result, :ash_onetime_boundary, %{seqs: seqs})}

      _other ->
        {:ok, result}
    end
  end

  # Compile-time shapes: leaves may be literals or argument/attribute
  # references; the resolved expression is validated by Boundary at runtime.
  defp query_shape({:tag, leaf}), do: leaf_shape(leaf)
  defp query_shape({:type, leaf}), do: leaf_shape(leaf)

  defp query_shape({kind, branches}) when kind in [:any, :all] and is_list(branches) do
    if branches != [] and Enum.all?(branches, &(query_shape(&1) == :ok)) do
      :ok
    else
      {:error, "context_boundary query shape is invalid"}
    end
  end

  defp query_shape({:not, inner}), do: query_shape(inner)
  defp query_shape(_other), do: {:error, "context_boundary query shape is invalid"}

  defp leaf_shape(value) when is_binary(value), do: :ok

  defp leaf_shape({source, _name}) when source in [:argument, :attribute], do: :ok
  defp leaf_shape(_other), do: {:error, "context_boundary query shape is invalid"}

  defp reference_shape({source, _name}) when source in [:argument, :attribute], do: :ok
  defp reference_shape(_other), do: {:error, "context_boundary reference shape is invalid"}

  defp tenant_shape(value) when is_binary(value), do: :ok

  defp tenant_shape({source, _name}) when source in [:argument, :attribute], do: :ok
  defp tenant_shape(nil), do: :ok
  defp tenant_shape(_other), do: {:error, "context_boundary tenant shape is invalid"}

  # Runtime resolution: references read arguments first, then set attributes.
  defp resolve_query(expr, changeset), do: {:ok, resolve_leaves(expr, changeset)}

  defp resolve_leaves({:tag, leaf}, changeset), do: {:tag, resolve_leaf(leaf, changeset)}
  defp resolve_leaves({:type, leaf}, changeset), do: {:type, resolve_leaf(leaf, changeset)}

  defp resolve_leaves({kind, branches}, changeset) when kind in [:any, :all],
    do: {kind, Enum.map(branches, &resolve_leaves(&1, changeset))}

  defp resolve_leaves({:not, inner}, changeset), do: {:not, resolve_leaves(inner, changeset)}

  defp resolve_leaf(value, _changeset) when is_binary(value), do: value

  defp resolve_leaf({source, name}, changeset) when source in [:argument, :attribute] do
    changeset
    |> fetch_reference(source, name)
    |> stringify()
  end

  defp resolve_reference({source, name}, changeset) when source in [:argument, :attribute] do
    case fetch_reference(changeset, source, name) do
      :error -> {:error, Error.new(:invalid_request, "context boundary reference is missing")}
      value -> {:ok, value}
    end
  end

  defp resolve_tenant(nil, changeset) do
    case changeset.tenant do
      tenant when is_binary(tenant) -> {:ok, tenant}
      _other -> {:error, Error.new(:invalid_request, "context boundary requires a tenant")}
    end
  end

  defp resolve_tenant({source, name}, changeset) when source in [:argument, :attribute] do
    case fetch_reference(changeset, source, name) do
      :error -> {:error, Error.new(:invalid_request, "context boundary tenant is missing")}
      value -> {:ok, stringify(value)}
    end
  end

  defp resolve_tenant(tenant, _changeset) when is_binary(tenant), do: {:ok, tenant}

  defp fetch_reference(changeset, :argument, name) do
    case Ash.Changeset.fetch_argument(changeset, name) do
      {:ok, value} -> value
      :error -> fetch_attribute(changeset, name)
    end
  end

  defp fetch_reference(changeset, :attribute, name), do: fetch_attribute(changeset, name)

  defp fetch_attribute(changeset, name) do
    case Ash.Changeset.fetch_change(changeset, name) do
      {:ok, value} ->
        value

      :error ->
        case Ash.Changeset.get_attribute(changeset, name) do
          nil -> :error
          value -> value
        end
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value) or is_integer(value), do: to_string(value)
  defp stringify(_other), do: :error
end
