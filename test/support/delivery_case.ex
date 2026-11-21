defmodule AshOnetime.Test.DeliveryCase do
  @moduledoc false

  # Shared setup and subject builders for the executing-only delivery tests. Every test
  # runs the real `AshOnetime.deliver/2` against the real store in PostgreSQL.

  alias Ash.Error.Invalid
  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples.Resource
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @routes [:create, :update, :destroy, :soft_destroy, :generic]

  def routes, do: @routes

  def install!(prefix) do
    for table <- ["ash_onetime_delivery_examples", "ash_onetime_delivery_guarded"] do
      SQL.query!(
        Repo,
        """
        CREATE TABLE IF NOT EXISTS "#{prefix}"."#{table}" (
          id uuid PRIMARY KEY,
          amount bigint NOT NULL,
          retired boolean NOT NULL DEFAULT false
        )
        """,
        []
      )
    end

    :ok
  end

  def unique_key(label), do: "#{label}-#{System.unique_integer([:positive])}"

  @doc """
  Returns a function that builds a fresh subject for `route` under `key`. Update and
  destroy routes act on one seeded record, the same record on every build.
  """
  def builder(prefix, route, key) do
    record = if route in [:update, :destroy, :soft_destroy], do: seed!(prefix)
    fn -> subject(prefix, route, key, record) end
  end

  def seed!(prefix) do
    Resource
    |> Ash.Changeset.for_create(:seed, %{amount: 1}, tenant: prefix)
    |> Ash.create!()
  end

  defp subject(prefix, :create, key, nil),
    do: Ash.Changeset.for_create(Resource, :issue, %{amount: 1, request_key: key}, tenant: prefix)

  defp subject(prefix, :update, key, record),
    do: Ash.Changeset.for_update(record, :rotate, %{amount: 2, request_key: key}, tenant: prefix)

  defp subject(prefix, :destroy, key, record),
    do: Ash.Changeset.for_destroy(record, :revoke, %{request_key: key}, tenant: prefix)

  defp subject(prefix, :soft_destroy, key, record),
    do: Ash.Changeset.for_destroy(record, :retire, %{request_key: key}, tenant: prefix)

  defp subject(prefix, :generic, key, nil),
    do: Ash.ActionInput.for_action(Resource, :mint, %{value: 1, request_key: key}, tenant: prefix)

  @doc """
  Executed deliveries with values, searched through the shapes a test collects
  (deliver returns, rollback reasons). Each value tuple counts as one delivery;
  neither the declared names nor their count change that. Only the count is reported.
  """
  def delivered(results) when is_list(results), do: Enum.flat_map(results, &delivered/1)

  def delivered(%Delivery{outcome: :executed, values: values}) when map_size(values) > 0,
    do: [values]

  def delivered(%Delivery{}), do: []
  def delivered(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> delivered()
  def delivered(_other), do: []

  @doc """
  The guarantee: at most one delivery of values per key. Fails on the second with its count,
  never the value.
  """
  defmacro assert_at_most_one_value(results) do
    quote do
      count = length(unquote(__MODULE__).delivered(unquote(results)))

      assert count <= 1,
             "#{count} executing-only deliveries carried values for one key"
    end
  end

  @doc "The number of idempotency claims in the installation `prefix`."
  def claim_count(prefix) do
    %{rows: [[count]]} =
      SQL.query!(Repo, ~s[SELECT count(*) FROM "#{prefix}"."ash_onetime_idempotency_claims"], [])

    count
  end

  @doc "The error code carried by a `deliver/2` error, or `nil`."
  def error_code({:error, error}), do: AshOnetime.Error.code(error)
  def error_code(_other), do: nil

  @doc "Adds `func` as a hook of `kind` to a changeset or an action input."
  def hook(%Ash.Changeset{} = changeset, :around_action, func, opts),
    do: Ash.Changeset.around_action(changeset, func, opts)

  def hook(%Ash.Changeset{} = changeset, :after_action, func, opts),
    do: Ash.Changeset.after_action(changeset, func, opts)

  def hook(%Ash.Changeset{} = changeset, :before_transaction, func, opts),
    do: Ash.Changeset.before_transaction(changeset, func, opts)

  def hook(%Ash.Changeset{} = changeset, :after_transaction, func, opts),
    do: Ash.Changeset.after_transaction(changeset, func, opts)

  def hook(%Ash.ActionInput{} = input, :after_action, func, opts),
    do: Ash.ActionInput.after_action(input, func, opts)

  def hook(%Ash.ActionInput{} = input, :before_transaction, func, opts),
    do: Ash.ActionInput.before_transaction(input, func, opts)

  def hook(%Ash.ActionInput{} = input, :after_transaction, func, opts),
    do: Ash.ActionInput.after_transaction(input, func, opts)

  @doc """
  Fails the action after the package's entry has completed, once per process flag:
  a CRUD action through an around-action prepended outside the package's, a generic
  action through an after-action appended after the package's.
  """
  def fail_after_completion(%Ash.Changeset{} = changeset, flag),
    do: hook(changeset, :around_action, &fail_completed(&1, &2, flag), prepend?: true)

  def fail_after_completion(%Ash.ActionInput{} = input, flag) do
    hook(
      input,
      :after_action,
      fn _input, result ->
        if Process.delete(flag), do: {:error, Invalid.exception(errors: [])}, else: {:ok, result}
      end,
      []
    )
  end

  defp fail_completed(changeset, callback, flag) do
    case callback.(changeset) do
      {:ok, _result, _changeset, _instructions} = completed ->
        if Process.delete(flag), do: {:error, Invalid.exception(errors: [])}, else: completed

      other ->
        other
    end
  end

  @doc "Fails a CRUD action from an after-action hook, which the package's entry encloses."
  def fail_in_after_action(%Ash.Changeset{} = changeset, flag) do
    hook(
      changeset,
      :after_action,
      fn _changeset, result ->
        if Process.delete(flag),
          do: {:error, Invalid.exception(errors: [])},
          else: {:ok, result}
      end,
      []
    )
  end

  @doc "An after-transaction hook that turns the action's error into success."
  def recover_errors(%Ash.Changeset{} = changeset) do
    hook(
      changeset,
      :after_transaction,
      fn
        recovered, {:error, _error} -> {:ok, recovered.data}
        _changeset, result -> result
      end,
      []
    )
  end

  def recover_errors(%Ash.ActionInput{} = input) do
    hook(
      input,
      :after_transaction,
      fn
        _input, {:error, _error} -> {:ok, 0}
        _input, result -> result
      end,
      []
    )
  end
end
