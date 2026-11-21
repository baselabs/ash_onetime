defmodule AshOnetime.Test.ExitBoundary.Refusals do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Test.ExitBoundary.{PathFrames, References, Scenarios}

  @wrapper {Delivery, :"-deliver/2-fun-0-", 1}
  @code :executing_only_in_transaction
  @message "executing-only delivery cannot run inside an open transaction"

  # The caller-transaction twin deliberately never enters Ash. Its stack source
  # is captured before the refusal. All extra error construction is built from
  # the public error constructor and compiled call locations, independently of
  # the error and stack being checked.
  def check(%{row: %{branch: :transaction}} = side, indexed) do
    caller = side.run.snapshot.root

    source =
      Enum.find_value(indexed.events, fn
        %{
          event:
            {^caller, :return_from, {:erlang, :process_info, 2}, {:current_stacktrace, stack}},
          stack: [{:erlang, :process_info, 2}, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}]
        } ->
          stack

        _ ->
          nil
      end)

    if source == nil do
      %{
        claimed: MapSet.new(),
        errors: [
          %{rule: :entry_stack_source, at: :entry, path: [], run: :missing, twin: :paired_source}
        ]
      }
    else
      error = AshOnetime.Error.new(@code, @message)

      constructor =
        References.capture(
          fn -> AshOnetime.Error.new(@code, @message) end,
          {AshOnetime.Error, :new, 2}
        )

      class = References.capture(fn -> class(error) end, {__MODULE__, :class, 1})
      reference_owner = hd(class).pid
      middle = Enum.slice(class, 1, length(class) - 2)

      original_stack =
        Enum.find_value(middle, fn
          %{event: {_, :return_from, {:erlang, :process_info, 2}, {:current_stacktrace, stack}}} ->
            stack

          _ ->
            nil
        end)

      [{Process, :info, 2, _}, scenario | base] = source
      {module, function, arity, _} = scenario

      common = [
        {module, function, arity, PathFrames.location(Scenarios, {:invoke, 1, :deliver, 1})}
        | base
      ]

      expected_native =
        Enum.take_while(original_stack, fn {m, _, _, _} -> m != __MODULE__ end) ++
          [
            {Delivery, elem(@wrapper, 1), 1,
             PathFrames.location(Delivery, {:deliver, 2, :to_error_class, 1, 0})}
            | common
          ]

      expected_native = Enum.take(expected_native, 64)
      {filter_call, _} = Enum.split_while(middle, &(&1.mfa != {Splode, :filter_stacktrace, 2}))
      filter_start = length(filter_call)

      filter_end =
        Enum.find_index(Enum.drop(middle, filter_start), fn e ->
          e.event
          |> Tuple.to_list()
          |> Enum.take(3)
          |> then(&match?([_, :return_from, {Splode, :filter_stacktrace, 2}], &1))
        end) + filter_start

      {_, :call, {Splode, :filter_stacktrace, [original_filter_input, filters]}} =
        Enum.at(middle, filter_start).event

      expected_stack = Enum.drop(expected_native, 1)
      {_, :return_from, _, original_filtered} = Enum.at(middle, filter_end).event

      filter =
        References.capture(
          fn -> Splode.filter_stacktrace(expected_stack, filters) end,
          {Splode, :filter_stacktrace, 2}
        )

      expected_filtered = filter |> List.last() |> Map.fetch!(:event) |> elem(3)

      replacements = [
        {reference_owner, caller},
        {original_stack, expected_native},
        {original_filter_input, expected_stack},
        {original_filtered, expected_filtered}
      ]

      prefix = Enum.take(middle, filter_start) |> Enum.map(&replace(&1.event, replacements))
      suffix = Enum.drop(middle, filter_end + 1) |> Enum.map(&replace(&1.event, replacements))
      filtered = Enum.map(filter, fn e -> put_elem(e.event, 0, caller) end)

      result =
        class |> List.last() |> Map.fetch!(:event) |> elem(3) |> elem(1) |> replace(replacements)

      expected =
        Enum.map(constructor, &put_elem(&1.event, 0, caller)) ++
          [{caller, :call, {Delivery, elem(@wrapper, 1), [{:error, error}]}}] ++
          prefix ++
          filtered ++
          suffix ++
          [{caller, :return_from, @wrapper, {:error, result}}]

      actual =
        Enum.filter(indexed.events, fn e ->
          e.pid == caller and
            (e.mfa == @wrapper or @wrapper in e.stack or
               ({Delivery, :in_transaction, 0} in e.stack and
                  elem(e.mfa || {nil}, 0) == AshOnetime.Error))
        end)

      errors = differences(actual, expected)
      %{claimed: MapSet.new(actual, & &1.index), errors: errors, result: result}
    end
  end

  def check(_side, _indexed), do: %{claimed: MapSet.new(), errors: []}

  # Keep the public conversion on the stack for the independent reference.
  def class(error) do
    result = Ash.Error.to_error_class(error)
    {:reference, result}
  end

  defp differences(actual, expected) do
    count = max(length(actual), length(expected))

    for n <- 0..(count - 1),
        event = Enum.at(actual, n),
        left = if(event, do: event.event, else: :absent),
        right = Enum.at(expected, n, :absent),
        left !== right do
      %{
        rule: :entry_refusal,
        at: if(event, do: Map.take(event, [:mfa, :index, :role]), else: :entry),
        path: [n],
        run: left,
        twin: right
      }
    end
  end

  defp replace(value, replacements) do
    case Enum.find(replacements, fn {source, _} -> value === source end) do
      {_, expected} ->
        expected

      nil ->
        descend(value, replacements)
    end
  end

  defp descend(value, replacements) when is_map(value),
    do: Map.new(Map.to_list(value), fn {key, item} -> {key, replace(item, replacements)} end)

  defp descend(value, replacements) when is_list(value),
    do: Enum.map(value, &replace(&1, replacements))

  defp descend(value, replacements) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&replace(&1, replacements)) |> List.to_tuple()

  defp descend(value, _replacements), do: value
end
