defmodule AshOnetime.Test.ExitBoundary.References do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.{Domain, Registry}

  def breadcrumbs(side, kind) do
    resource = side.resource
    action = side.row.action
    type = side.row.type
    memo({:breadcrumbs, resource, action, type, kind, side.prefix}, fn ->
      declaration = Ash.Resource.Info.action(resource, action)
      hook = fn _subject, _callback ->
        error = AshOnetime.Error.new(:diagnostic_reference, "diagnostic reference")
        if kind == :raise, do: raise(error), else: {:error, error}
      end
      # A fresh action with a terminal transaction hook reaches Ash's own error
      # construction before a write. Neither its inputs nor its result contain
      # a checked error, a delivery value, or a copied diagnostic string.
      subject = if type == :action do
        %Ash.ActionInput{resource: resource, action: declaration, domain: Domain,
          tenant: side.prefix, around_transaction: [hook]}
      else
        %Ash.Changeset{resource: resource, data: struct(resource), action: declaration,
          action_type: type, domain: Domain, tenant: side.prefix, to_tenant: side.prefix,
          __validated_for_action__: action, around_transaction: [hook],
          dirty_hooks: [:around_transaction]}
      end
      {module, function, arity} = Map.fetch!(Registry.rule!(:o2a_diagnostic).entries, type)
      opts = [authorize?: false, atomic_upgrade?: false]
      args = if arity == 3, do: [Domain, subject, opts], else: [Domain, subject, declaration, opts]
      result = try do
        apply(module, function, args)
      rescue
        error -> error
      end
      case collect_breadcrumbs(result) |> Enum.uniq() do
        [crumb] -> crumb
        _ -> raise "the Ash diagnostic reference did not produce one bound breadcrumb"
      end
    end)
  end

  defp collect_breadcrumbs(%{bread_crumbs: crumbs} = error),
    do: crumbs ++ Enum.flat_map(List.wrap(Map.get(error, :errors)), &collect_breadcrumbs/1)
  defp collect_breadcrumbs({:error, error}), do: collect_breadcrumbs(error)
  defp collect_breadcrumbs(_), do: []

  def capture(fun, target, setup \\ fn -> :ok end) do
    run = ExitBoundary.observe(setup, fn _ -> fun.() end,
      %{host: [], frames: [target], callbacks: [AshOnetime.Test.ExitBoundary.Codec, AshOnetime.Test.ExitBoundary.ResponseClassifier]})
    run.events |> Enum.filter(fn e -> e.mfa == target or target in e.stack end)
  end

  def query_name(id, metadata) do
    memo({:query_name, id, metadata.pid}, fn ->
      target = {Ecto.Adapters.SQL, :prepare_name, 2}
      capture(fn ->
        Ecto.Adapters.SQL.execute(:named, metadata, %{},
          {:cache, fn _ -> :ok end, {id, "SELECT 1"}}, [], log: false)
      end, target)
      |> Enum.find_value(fn
        %{event: {_, :return_from, ^target, name}} -> {:name, name}
        _ -> nil
      end)
      |> case do {:name, name} -> name end
    end)
  end

  def protection(resource, action) do
    memo({:protection, resource, action}, fn -> protection_reference(resource, action) end)
  end
  defp protection_reference(resource, action) do
    target = {AshOnetime.Resource.Info, :protection, 2}
    capture(fn -> AshOnetime.Resource.Info.protection(resource, action) end, target) |> index()
  end

  def contract(resource, action, prefix) do
    memo({:contract, resource, action, prefix}, fn -> contract_reference(resource, action, prefix) end)
  end
  defp contract_reference(resource, action, prefix) do
    protection = AshOnetime.Resource.Info.protection(resource, action)
    type = Ash.Resource.Info.action(resource, action).type
    trusted = %{limits: protection.limits, tenant: prefix}
    trusted = if type == :destroy, do: Map.put(trusted, :return_destroyed?, true), else: trusted
    args = [resource, action, protection.response, trusted]
    target = {AshOnetime.Response, :contract, 4}
    %{args: args, events: capture(fn -> apply(AshOnetime.Response, :contract, args) end, target) |> index(),
      result: apply(AshOnetime.Response, :contract, args)}
  end

  def operation(resource, action) do
    memo({:operation, resource, action}, fn -> operation_reference(resource, action) end)
  end
  defp operation_reference(resource, action) do
    descriptor = %{domain: :operation, resource: inspect(resource), action: action}
    run = ExitBoundary.observe(fn -> descriptor end, &AshOnetime.Fingerprint.compute/1,
      %{host: [], callbacks: []})
    target = {AshOnetime.Fingerprint, :compute, 1}
    run.events |> Enum.filter(fn e -> e.mfa == target or target in e.stack end)
      |> index()
  end

  def operation_slots(events, reference) do
    target = {AshOnetime.Fingerprint, :compute, 1}
    {slots, _state} = Enum.reduce(events, {%{}, %{}}, fn e, {slots, counters} ->
      cond do
        e.mfa == {AshOnetime.Admission, :operation_hash, 1} and elem(e.event, 1) == :call ->
          {slots, Map.put(counters, e.pid, %{})}
        {AshOnetime.Admission, :operation_hash, 1} in e.stack and
            (e.mfa == target or target in e.stack) ->
          payload = Tuple.delete_at(e.event, 0)
          key = {elem(payload, 0), e.mfa}
          counts = Map.get(counters, e.pid, %{})
          ordinal = Map.get(counts, key, 0)
          expected = Enum.find_value(reference, :undeclared_reference_event, fn
            {^key, ^ordinal, value} -> {:expected, value}
            _ -> nil
          end)
          {Map.put(slots, e.index, expected), put_in(counters[e.pid], Map.put(counts, key, ordinal + 1))}
        true -> {slots, counters}
      end
    end)
    slots
  end

  # These are positions in the package's fixed locator-validation call graph.
  # Their values must still equal operation(resource, action) on each side.
  def locator_copies(events) do
    {slots, _} = Enum.reduce(events, {%{}, %{}}, fn e, {slots, frames} ->
      case e.event do
        {pid, :call, {AshOnetime.Admission, f, _}} when f in [:valid_locator_hashes?, :equal_locator_hashes?] ->
          {slots, Map.put(frames, {pid, f}, 0)}
        {pid, :call, {AshOnetime.Admission, :valid_hash?, _}} ->
          key = {pid, :valid_locator_hashes?}
          if {AshOnetime.Admission, :valid_locator_hashes?, 2} in e.stack do
            n = Map.fetch!(frames, key)
            paths = if n in [0, 3], do: [[:event, 2, 2, 0]], else: []
            {Map.put(slots, e.index, paths), Map.put(frames, key, n + 1)}
          else
            {slots, frames}
          end
        {pid, :call, {:crypto, :hash_equals, _}} ->
          key = {pid, :equal_locator_hashes?}
          if {AshOnetime.Admission, :equal_locator_hashes?, 2} in e.stack do
            n = Map.fetch!(frames, key)
            paths = if n == 0, do: [[:event, 2, 2, 0], [:event, 2, 2, 1]], else: []
            {Map.put(slots, e.index, paths), Map.put(frames, key, n + 1)}
          else
            {slots, frames}
          end
        {pid, :call, {:crypto, :hash_equals_nif, _}} ->
          if {AshOnetime.Admission, :equal_locator_hashes?, 2} in e.stack and
               Map.get(frames, {pid, :equal_locator_hashes?}) == 1 do
            {Map.put(slots, e.index, [[:event, 2, 2, 0], [:event, 2, 2, 1]]), frames}
          else
            {slots, frames}
          end
        _ -> {slots, frames}
      end
    end)
    slots
  end

  def index(events) do
    {indexed, _} = Enum.map_reduce(events, %{}, fn e, counters ->
      event = Tuple.delete_at(e.event, 0)
      key = {elem(event, 0), e.mfa}
      n = Map.get(counters, key, 0)
      {{key, n, event}, Map.put(counters, key, n + 1)}
    end)
    indexed
  end

  def memo(key, fun) do
    key = {__MODULE__, :reference, key}
    case Process.get(key) do
      nil -> value = fun.(); Process.put(key, {:value, value}); value
      {:value, value} -> value
    end
  end
end
