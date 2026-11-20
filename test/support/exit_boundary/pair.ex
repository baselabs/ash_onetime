defmodule AshOnetime.Test.ExitBoundary.Pair do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Withheld

  defmodule Path do
    @moduledoc false
    # `action` is the action of both resources; `external?` whether it runs an external
    # effect; `fault` the mode planted in both roots; `input` the action's input;
    # `opts` the call's options; `record` whether the action targets a seeded record;
    # `call` how the run side calls it: `:deliver`, or `:direct` (the Ash call itself);
    # `transaction` a caller transaction around the call, `:commit` or `:rollback`, in
    # which the twin opens the same transaction and does nothing.
    defstruct [
      :action,
      :type,
      :fault,
      :key,
      :transaction,
      call: :deliver,
      external?: false,
      input: %{},
      opts: [],
      record: false
    ]
  end

  @doc "Seeds one record in `prefix` through the test's connection, committed."
  def seed!(resource, prefix) do
    resource
    |> Ash.Changeset.for_create(:seed, %{amount: 1}, tenant: prefix)
    |> Ash.create!()
  end

  @doc "The path's subject, built for `resource` in `prefix`."
  def subject(%Path{type: :action} = path, resource, prefix, _record) do
    Ash.ActionInput.for_action(resource, path.action, input(path), tenant: prefix)
  end

  def subject(%Path{type: :create} = path, resource, prefix, _record) do
    Ash.Changeset.for_create(resource, path.action, input(path), tenant: prefix)
  end

  def subject(%Path{type: :update} = path, _resource, prefix, record) do
    Ash.Changeset.for_update(record, path.action, input(path), tenant: prefix)
  end

  def subject(%Path{type: :destroy} = path, _resource, prefix, record) do
    Ash.Changeset.for_destroy(record, path.action, input(path), tenant: prefix)
  end

  defp input(path), do: Map.put(path.input, :request_key, path.key)

  @doc "The side's call of `subject`: what a prior call and the observed call both run."
  def run_call(Withheld, %Path{call: :deliver} = path, subject),
    do: AshOnetime.deliver(subject, path.opts)

  def run_call(_resource, path, subject), do: call(subject, path.opts)

  @doc "The Ash call `deliver/2` makes for `subject`."
  def call(%Ash.Changeset{action: %{type: :create}} = changeset, opts),
    do: Ash.create(changeset, opts)

  def call(%Ash.Changeset{action: %{type: :update}} = changeset, opts),
    do: Ash.update(changeset, Keyword.put(opts, :atomic_upgrade?, false))

  def call(%Ash.Changeset{action: %{type: :destroy}} = changeset, opts),
    do: Ash.destroy(changeset, opts)

  def call(%Ash.ActionInput{} = input, opts), do: Ash.run_action(input, opts)

end
