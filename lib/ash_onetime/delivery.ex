defmodule AshOnetime.Delivery do
  @moduledoc """
  The executing-only values one `AshOnetime.deliver/2` call received.

  `outcome` says which path completed the call:

    * `:executed` — this call executed the effect; `values` holds every declared
      `executing_only` value, exactly once.
    * `:replayed` — a stored completion for the same key and request was replayed;
      `values` is empty. An earlier call may have lost the value before delivery.
    * `:recovered` — an external effect's earlier execution was recovered; `values` is
      empty.

  A value lost after its transaction committed is lost for good: no path re-derives it.
  The remedy is to revoke what it granted and reissue under a new key.

  `inspect/1` prints the outcome and the value names only.
  """

  alias AshOnetime.Delivery.Envelope
  alias AshOnetime.Error
  alias AshOnetime.Resource.Info
  alias AshOnetime.Store

  defstruct [:outcome, values: %{}]

  @type outcome :: :executed | :replayed | :recovered
  @type t :: %__MODULE__{outcome: outcome(), values: %{optional(atom()) => binary()}}

  @reference :ash_onetime_delivery
  @cell :ash_onetime_delivery_cell
  @bulk_keys [:bulk_create, :bulk_update, :bulk_destroy]

  @doc false
  @spec deliver(Ash.Changeset.t() | Ash.ActionInput.t(), keyword()) ::
          {:ok, term(), t()}
          | {:ok, term(), [Ash.Notifier.Notification.t()], t()}
          | {:error, term()}
  def deliver(subject, opts) when is_list(opts) do
    with {:ok, protection} <- protection(subject),
         :ok <- route(subject, opts),
         {:ok, cell} <- cell(subject) do
      armed_call(subject, protection, cell, opts)
    else
      {:error, %Error{} = error} -> {:error, Ash.Error.to_error_class(error)}
    end
  end

  def deliver(_subject, _opts), do: {:error, Ash.Error.to_error_class(refused())}

  # Rule 1: everything the entry needs lives in this process's dictionary under a hash of
  # the reference; the subject's context carries the reference only. The private key
  # never leaves this process. This frame owns the entry: it arms it, runs the call, and
  # erases it however the call ends. When the call raises, exits or throws, the erase is
  # followed by raising the same term again from here, the one event this frame adds to
  # what the caller receives from Ash.
  defp armed_call(subject, protection, cell, opts) do
    {public, secret} = :crypto.generate_key(:ecdh, :x25519)
    ref = :crypto.strong_rand_bytes(16)
    key = key(ref)

    try do
      Process.put(key, {:armed, self(), subject.resource, subject.action.name, cell, public})
      armed(subject, protection, {key, ref, secret, public}, opts)
    after
      Process.delete(key)
    end
  end

  defp armed(subject, protection, {key, ref, secret, public}, opts) do
    resource = subject.resource
    action = subject.action.name

    subject
    |> put_reference(ref)
    |> dispatch(opts)
    |> normalize(subject.action.type, opts)
    |> finish(fn -> open(key, ref, secret, public, protection, resource, action) end)
  end

  defp dispatch(%Ash.Changeset{action: %{type: :create}} = changeset, opts),
    do: Ash.create(changeset, opts)

  defp dispatch(%Ash.Changeset{action: %{type: :update}} = changeset, opts),
    do: Ash.update(changeset, Keyword.put(opts, :atomic_upgrade?, false))

  defp dispatch(%Ash.Changeset{action: %{type: :destroy}} = changeset, opts),
    do: Ash.destroy(changeset, opts)

  defp dispatch(%Ash.ActionInput{} = input, opts), do: Ash.run_action(input, opts)

  defp normalize({:error, _error} = error, _type, _opts), do: error
  defp normalize(:ok, _type, _opts), do: {:ok, nil}
  defp normalize({:ok, result, notifications}, _type, _opts), do: {:ok, result, notifications}

  defp normalize({:ok, value}, :destroy, opts) do
    if opts[:return_notifications?] && !opts[:return_destroyed?],
      do: {:ok, nil, value},
      else: {:ok, value}
  end

  defp normalize({:ok, result}, _type, _opts), do: {:ok, result}

  defp finish({:error, _error} = error, _open), do: error

  defp finish({:ok, result}, open) do
    with {:ok, delivery} <- open.(), do: {:ok, result, delivery}
  end

  defp finish({:ok, result, notifications}, open) do
    with {:ok, delivery} <- open.(), do: {:ok, result, notifications, delivery}
  end

  # An executed value opens only when the store holds the committed completion of the
  # exact claim that produced it, read here, after Ash returned and outside any
  # transaction. A rollback that a later hook turned into success leaves no completion.
  defp open(key, ref, secret, public, protection, resource, action) do
    case Process.get(key) do
      {:done, inv, :executed, envelope, {target, claim}} when is_binary(envelope) ->
        with :complete <- Store.committed_completion(target, claim),
             names = protection.executing_only,
             context = Envelope.context(ref, inv, resource, action),
             {:ok, values} <- Envelope.open(envelope, secret, public, length(names), context) do
          {:ok, %__MODULE__{outcome: :executed, values: Map.new(Enum.zip(names, values))}}
        else
          _other -> lost_class()
        end

      {:done, _inv, outcome, nil, nil} when outcome in [:replayed, :recovered] ->
        {:ok, %__MODULE__{outcome: outcome, values: %{}}}

      _other ->
        lost_class()
    end
  rescue
    _exception -> lost_class()
  catch
    _kind, _reason -> lost_class()
  end

  defp protection(%{resource: resource, action: %{name: name, type: type}} = subject)
       when is_atom(resource) and is_atom(name) do
    with true <- subject_type?(subject, type),
         %{executing_only: [_ | _]} = protection <- Info.protection(resource, name) do
      {:ok, protection}
    else
      _other -> {:error, refused()}
    end
  rescue
    _exception -> {:error, refused()}
  end

  defp protection(_subject), do: {:error, refused()}

  defp subject_type?(%Ash.Changeset{}, type), do: type in [:create, :update, :destroy]
  defp subject_type?(%Ash.ActionInput{}, type), do: type == :action
  defp subject_type?(_subject, _type), do: false

  # Route refusals before arming (§2.7.4): an open transaction, which could roll back
  # after the value was returned, and the conditions under which the package's entry
  # would not run, or would run in another process.
  defp route(subject, opts) do
    cond do
      Ash.DataLayer.in_transaction?(subject.resource) -> {:error, in_transaction()}
      bulk?(subject) -> {:error, refused()}
      not built_for_action?(subject) -> {:error, refused()}
      task_route?(subject, opts) -> {:error, refused()}
      true -> :ok
    end
  end

  defp bulk?(%{context: context}) when is_map(context),
    do: Enum.any?(@bulk_keys, &Map.has_key?(context, &1))

  defp bulk?(_subject), do: false

  defp built_for_action?(%Ash.Changeset{__validated_for_action__: name, action: %{name: name}}),
    do: true

  defp built_for_action?(%Ash.Changeset{}), do: false
  defp built_for_action?(%Ash.ActionInput{}), do: true

  # Ash takes its Task route exactly when all five hold (changeset.ex:4782-4796, :4864-4869;
  # process_helpers.ex:66-74): the four below, and no open transaction, which always holds
  # here because an open transaction is refused first. The transaction branch follows the
  # action Ash runs, which is the changeset's own action struct (helpers.ex:277-287);
  # `Ash.create/2`, `update/2` and `destroy/2` accept no `transaction?` option. Generic
  # actions never take it.
  defp task_route?(%Ash.Changeset{} = changeset, opts) do
    resource = changeset.resource
    timeout = opts[:timeout] || changeset.timeout

    not (changeset.action.transaction? and Ash.DataLayer.data_layer_can?(resource, :transact)) and
      not is_nil(timeout) and timeout != :infinity and
      !Application.get_env(:ash, :disable_async?) and
      Ash.DataLayer.data_layer_can?(resource, :async_engine)
  end

  defp task_route?(_subject, _opts), do: false

  defp cell(%{context: %{private: %{@cell => cell}}}) when is_reference(cell), do: {:ok, cell}
  defp cell(_subject), do: {:error, refused()}

  defp put_reference(subject, ref), do: put_private(subject, @reference, %{ref: ref})

  @doc false
  @spec put_cell(Ash.Changeset.t() | Ash.ActionInput.t()) ::
          {Ash.Changeset.t() | Ash.ActionInput.t(), reference()}
  def put_cell(subject) do
    cell = make_ref()
    {put_private(subject, @cell, cell), cell}
  end

  defp put_private(%{context: context} = subject, name, value) do
    private =
      case Map.get(context, :private) do
        %{} = private -> Map.put(private, name, value)
        _other -> %{name => value}
      end

    %{subject | context: Map.put(context, :private, private)}
  end

  @doc false
  @spec key(binary()) :: {module(), binary()}
  def key(ref), do: {__MODULE__, :crypto.hash(:sha256, ref)}

  defp reference(%{context: %{private: %{@reference => %{ref: ref}}}}) when is_binary(ref),
    do: {:ok, ref}

  defp reference(_subject), do: :error

  @doc false
  # The entry check (§2.7.3, step 2): the package entry's first act, and the only code
  # that claims the armed entry.
  @spec claim(Ash.Changeset.t() | Ash.ActionInput.t(), reference(), [atom()]) ::
          {:ok, map()} | {:error, Error.t()}
  def claim(subject, cell, names) do
    with {:ok, ref} <- reference(subject),
         key = key(ref),
         entry when not is_nil(entry) <- Process.get(key) do
      claim_entry(entry, key, ref, subject, cell, names)
    else
      _missing -> {:error, requires_call()}
    end
  end

  defp claim_entry(
         {:armed, pid, resource, action, entry_cell, public},
         key,
         ref,
         subject,
         cell,
         names
       ) do
    if pid == self() and resource == subject.resource and action == subject.action.name and
         entry_cell == cell do
      inv = :crypto.strong_rand_bytes(16)
      Process.put(key, {:claimed, inv, public})
      {:ok, %{key: key, ref: ref, inv: inv, resource: resource, action: action, names: names}}
    else
      {:error, refused()}
    end
  end

  defp claim_entry(_spent, _key, _ref, _subject, _cell, _names), do: {:error, lost()}

  @doc false
  # Produce and seal in one function and one containment boundary (§2.7.3, step 3).
  # `trusted` is admission's trusted context (actor and tenant only).
  @spec produce(map(), module(), Ash.Changeset.t() | Ash.ActionInput.t(), map()) ::
          :ok | {:error, Error.t()}
  def produce(handle, module, subject, trusted) do
    context =
      trusted
      |> Map.take([:actor, :tenant])
      |> Map.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.merge(%{resource: handle.resource, action: handle.action})

    case module.produce(subject, context) do
      {:ok, values} -> seal(handle, values)
      _other -> {:error, invalid()}
    end
  rescue
    _exception -> {:error, invalid()}
  catch
    _kind, _reason -> {:error, invalid()}
  end

  @doc false
  # Values outside the producer's contract are `:executing_only_invalid`. Well-formed values
  # that cannot be sealed to this call's entry (the entry is no longer claimed by this
  # invocation, or the envelope refuses its recipient key) can never reach this caller:
  # `:executing_only_lost`. Either way the action fails and rolls back.
  @spec seal(map(), term()) :: :ok | {:error, Error.t()}
  def seal(%{names: names} = handle, values) when is_map(values) do
    with true <- map_size(values) == length(names),
         {:ok, ordered} <- ordered_values(names, values) do
      seal_to_entry(handle, ordered)
    else
      _other -> {:error, invalid()}
    end
  end

  def seal(_handle, _values), do: {:error, invalid()}

  defp seal_to_entry(%{key: key, ref: ref, inv: inv} = handle, ordered) do
    with {:claimed, ^inv, public} <- Process.get(key),
         context = Envelope.context(ref, inv, handle.resource, handle.action),
         {:ok, envelope} <- Envelope.seal(public, ordered, context) do
      Process.put(key, {:sealed, inv, envelope})
      :ok
    else
      _other -> {:error, lost()}
    end
  end

  defp ordered_values(names, values) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, ordered} ->
      case deliverable(Map.fetch(values, name)) do
        {:ok, value} -> {:cont, {:ok, [value | ordered]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ordered} -> {:ok, Enum.reverse(ordered)}
      :error -> :error
    end
  end

  # A produced value is a binary within the envelope's per-value bound.
  defp deliverable({:ok, value}) when is_binary(value) do
    if byte_size(value) <= Envelope.max_value_bytes(), do: {:ok, value}, else: :error
  end

  defp deliverable(_other), do: :error

  @doc false
  # Complete (§2.7.3, step 4) for the CRUD entry, which holds its own handle. `state` is
  # admission's state: its `delivery_source` is the outcome, and an executed completion
  # keeps the store target and the exact claim for the committed read-back.
  @spec complete(map(), map()) :: :ok | {:error, Error.t()}
  def complete(%{key: key, inv: inv}, state), do: complete_entry(key, inv, state)

  @doc false
  # Complete for the generic after-action, which reads `inv` from the entry.
  @spec complete_current(Ash.ActionInput.t(), map()) :: :ok | {:error, Error.t()}
  def complete_current(subject, state) do
    with {:ok, ref} <- reference(subject),
         key = key(ref),
         {entry, inv, _value} when entry in [:claimed, :sealed] <- Process.get(key) do
      complete_entry(key, inv, state)
    else
      _other -> {:error, lost()}
    end
  end

  defp complete_entry(key, inv, %{delivery_source: outcome} = state) do
    case {Process.get(key), outcome, state} do
      {{:sealed, ^inv, envelope}, :executed, %{target: target, claim: %{id: id} = claim}}
      when not is_nil(target) and is_binary(id) ->
        Process.put(key, {:done, inv, :executed, envelope, {target, claim}})
        :ok

      # Only an executing admission produces, so a replay or a recovery completes an entry
      # that was claimed and never sealed.
      {{:claimed, ^inv, _public}, outcome, _state} when outcome in [:replayed, :recovered] ->
        Process.put(key, {:done, inv, outcome, nil, nil})
        :ok

      # §2.7.5: an external execute sealed its values, then `finalize` found the claim
      # completed and resolved to a replay. The completion that counts is the earlier one,
      # so this call is a replay: the envelope is dropped and `:done` carries nil. Any other
      # outcome on a sealed entry is lost.
      # mutation sentinel: finalize-replay-drop
      {{:sealed, ^inv, _envelope}, :replayed, _state} ->
        Process.put(key, {:done, inv, :replayed, nil, nil})
        :ok

      _other ->
        {:error, lost()}
    end
  end

  defp complete_entry(_key, _inv, _state), do: {:error, lost()}

  @doc false
  def lost, do: Error.new(:executing_only_lost, "executing-only values were lost")

  @doc false
  def invalid,
    do: Error.new(:executing_only_invalid, "executing-only values could not be produced")

  defp refused,
    do: Error.new(:executing_only_refused, "executing-only delivery was refused")

  defp in_transaction,
    do:
      Error.new(
        :executing_only_in_transaction,
        "executing-only delivery cannot run inside an open transaction"
      )

  defp requires_call,
    do:
      Error.new(
        :executing_only_requires_call,
        "an action with executing-only values runs only through AshOnetime.deliver/2"
      )

  defp lost_class, do: {:error, Ash.Error.to_error_class(lost())}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{outcome: outcome, values: values}, opts) do
      names = values |> Map.keys() |> Enum.sort()

      concat([
        "#AshOnetime.Delivery<",
        to_doc([outcome: outcome, values: names], opts),
        ">"
      ])
    end
  end
end
