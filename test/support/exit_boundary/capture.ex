defmodule AshOnetime.Test.ExitBoundary.Capture do
  alias AshOnetime.Test.ExitBoundary.Classifier
  alias AshOnetime.Test.ExitBoundary.FailureTwins
  alias AshOnetime.Test.ExitBoundary.Registry
  alias AshOnetime.Test.ExitBoundary.Root
  @moduledoc false

  def frames(host, callbacks) do
    package =
      for {module, _} <- :code.all_loaded(),
          module == AshOnetime or
            (String.starts_with?(Atom.to_string(module), "Elixir.AshOnetime.") and
               not String.starts_with?(Atom.to_string(module), "Elixir.AshOnetime.Test.")),
          do: {module, :_, :_}

    Enum.uniq(
      package ++
        Enum.map(host ++ callbacks, &{&1, :_, :_}) ++
        Registry.frames() ++
        FailureTwins.frames() ++
        [
          {Root, :invoke, 2},
          {Ash, :create, 2},
          {Ash, :update, 2},
          {Ash, :destroy, 2},
          {Ash, :run_action, 2}
        ]
    )
  end

  def patterns(session, frames, options \\ []) do
    for module <- Classifier.traced_modules(), Code.ensure_loaded?(module) do
      :trace.function(session, {module, :_, :_}, [{:_, [], [{:exception_trace}]}], [:local])
    end

    for {module, table} <- [
          {:erlang, Classifier.erlang_table()},
          {:erts_internal, Classifier.erts_internal_table()}
        ],
        {{function, arity}, :pure} <- table,
        not Keyword.get(options, :include_pure?, false),
        {module, function, arity} not in (Registry.generators() ++ Registry.clocks()) do
      :trace.function(session, {module, function, arity}, false, [:local])
    end

    for {module, function, arity} <- frames, Code.ensure_loaded?(module) do
      :trace.function(session, {module, function, arity}, [{:_, [], [{:exception_trace}]}], [
        :local
      ])
    end

    :trace.function(session, :on_load, [{:_, [], [{:exception_trace}]}], [:local])
  end

  def annotate(snapshot, spec \\ %{host: [], callbacks: []}) do
    frames = frames(spec.host, spec.callbacks) ++ Map.get(spec, :frames, [])

    {events, _} =
      Enum.map_reduce(snapshot.events, %{}, fn event, stacks ->
        owner = elem(event, 0)
        stack = Map.get(stacks, owner, [])

        {mfa, next} =
          case event do
            {_, :call, {m, f, args}} ->
              mfa = {m, f, length(args)}
              {mfa, [mfa | stack]}

            {_, tag, mfa, _} when tag in [:return_from, :exception_from] ->
              {_inner, rest} = Enum.split_while(stack, &(&1 != mfa))
              {mfa, Enum.drop(rest, 1)}

            _ ->
              {nil, stack}
          end

        class = classify(event, mfa, frames, spec.callbacks, snapshot.loaded_before)

        {%{pid: owner, event: event, mfa: mfa, stack: stack, class: class},
         Map.put(stacks, owner, next)}
      end)

    events
  end

  defp classify({_, :call, {module, function, args}} = event, _mfa, frames, callbacks, loaded) do
    class = Classifier.classify(event)

    cond do
      module in callbacks ->
        :e24

      class in Classifier.classes() ->
        class

      Enum.any?(frames, fn {m, f, a} ->
        m == module and f in [:_, function] and a in [:_, length(args)]
      end) ->
        :frame

      not MapSet.member?(loaded, module) ->
        :e18

      true ->
        class
    end
  end

  defp classify(event, _mfa, _frames, _callbacks, _loaded), do: Classifier.classify(event)
end
