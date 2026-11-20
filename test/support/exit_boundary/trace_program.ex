defmodule AshOnetime.Test.ExitBoundary.TraceProgram do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Delivery.Envelope
  alias AshOnetime.Test.ExitBoundary.{PermittedTrace, Returns}

  # A frame is a program node, rather than a region exemption. Its direct calls
  # have a closed order. Ordinary calls beneath these nodes still compare with
  # the twin; this table fixes the additional calls the delivery path may make.
  def check(side, events, bindings) do
    events
    |> Enum.filter(fn e -> match?({_, :call, _}, e.event) and PermittedTrace.frame?(e.mfa) end)
    |> Enum.flat_map(fn e ->
      children = children(events, e)
      expected = program(e.mfa, arguments(e), side, bindings)
      actual = Enum.map(children, & &1.mfa)

      order_errors =
        if expected == :ordinary or actual === expected,
          do: [],
          else: [order_difference(e, children, actual, expected)]

      order_errors ++ returns(events, e, side, bindings)
    end)
  end

  defp order_difference(root, children, actual, expected) do
    position =
      Enum.find(0..max(length(actual), length(expected)), fn n ->
        Enum.at(actual, n, :end) !== Enum.at(expected, n, :end)
      end)

    node = Enum.at(children, position) || root

    difference(
      node,
      :permitted_call_order,
      Enum.at(actual, position, :end),
      Enum.at(expected, position, :end)
    )
  end

  defp arguments(%{event: {_, :call, {_, _, arguments}}}), do: arguments

  defp children(events, root) do
    events
    |> Enum.filter(&(&1.index > root.index))
    |> Enum.take_while(fn e ->
      not (e.pid == root.pid and e.mfa == root.mfa and length(e.stack) == length(root.stack) + 1 and
             elem(e.event, 1) in [:return_from, :exception_from])
    end)
    |> Enum.filter(fn e ->
      e.pid == root.pid and elem(e.event, 1) == :call and e.stack == [root.mfa | root.stack]
    end)
  end

  defp program({AshOnetime, :deliver, 2}, _, _, _), do: [{Delivery, :deliver, 2}]

  defp program({Delivery, :deliver, 2}, _, %{row: %{branch: :transaction}}, _),
    do: [{Delivery, :protection, 1}, {Delivery, :route, 2}, {Delivery, :"-deliver/2-fun-0-", 1}]

  defp program({Delivery, :deliver, 2}, _, _, _),
    do: [
      {Delivery, :protection, 1},
      {Delivery, :route, 2},
      {Delivery, :cell, 1},
      {Delivery, :armed_call, 4}
    ]

  defp program({Delivery, :armed_call, 4}, _, _, _),
    do: [
      {:crypto, :generate_key, 2},
      {:crypto, :strong_rand_bytes, 1},
      {Delivery, :key, 1},
      {:erlang, :put, 2},
      {Delivery, :armed, 4},
      {:erlang, :erase, 1}
    ]

  defp program({Delivery, :armed, 4}, _, %{row: %{branch: :consumer_failure}}, _),
    do: [{Delivery, :put_reference, 2}, {Delivery, :dispatch, 2}]

  defp program({Delivery, :armed, 4}, _, _, _),
    do: [
      {Delivery, :put_reference, 2},
      {Delivery, :dispatch, 2},
      {Delivery, :normalize, 3},
      {Delivery, :finish, 2}
    ]

  defp program({Delivery, :dispatch, 2}, _, side, _) do
    function =
      %{create: :create, update: :update, destroy: :destroy, action: :run_action}[side.row.type]

    [{Ash, function, 2}]
  end

  defp program({Delivery, :normalize, 3}, _, _, _), do: []
  defp program({Delivery, :finish, 2}, [{:error, _}, _], _, _), do: []
  defp program({Delivery, :finish, 2}, _, _, _), do: [{Delivery, :"-armed/4-fun-0-", 7}]
  defp program({Delivery, :"-armed/4-fun-0-", 7}, _, _, _), do: [{Delivery, :open, 7}]

  defp program({Delivery, :open, 7}, _, %{row: %{branch: branch}}, _)
       when branch in [:replay, :recovered, :unknown, :finalize_replay], do: [{Process, :get, 1}]

  defp program({Delivery, :open, 7}, _, _, _),
    do: [
      {Process, :get, 1},
      {AshOnetime.Store, :committed_completion, 2},
      {Envelope, :context, 4},
      {Envelope, :open, 5}
    ]

  defp program({Delivery, :protection, 1}, _, _, _),
    do: [{Delivery, :subject_type?, 2}, {AshOnetime.Resource.Info, :protection, 2}]

  defp program({Delivery, :subject_type?, 2}, _, _, _), do: []
  defp program({Delivery, :route, 2}, _, %{row: %{branch: :transaction}}, _), do: :ordinary
  defp program({Delivery, :route, 2}, _, _, _), do: :ordinary

  defp program({Delivery, :bulk?, 1}, _, _, _),
    do: List.duplicate({Delivery, :"-bulk?/1-fun-0-", 2}, 3)

  defp program({Delivery, f, _}, _, _, _)
       when f in [
              :"-bulk?/1-fun-0-",
              :built_for_action?,
              :task_route?,
              :cell,
              :put_private,
              :reference
            ],
       do: []

  defp program({Delivery, :put_cell, 1}, _, _, _),
    do: [{:erlang, :make_ref, 0}, {Delivery, :put_private, 3}]

  defp program({Delivery, :put_reference, 2}, _, _, _), do: [{Delivery, :put_private, 3}]
  defp program({Delivery, :key, 1}, _, _, _), do: [{:crypto, :hash, 2}]

  defp program({Delivery, :claim, 3}, _, %{row: %{branch: :direct}}, _),
    do: [{Delivery, :reference, 1}, {Delivery, :"-claim/3-fun-0-", 1}]

  defp program({Delivery, :claim, 3}, _, _, _),
    do: [
      {Delivery, :reference, 1},
      {Delivery, :key, 1},
      {Process, :get, 1},
      {Delivery, :claim_entry, 6}
    ]

  defp program({Delivery, :"-claim/3-fun-0-", 1}, _, _, _), do: [{Delivery, :requires_call, 0}]

  defp program({Delivery, :claim_entry, 6}, _, _, _),
    do: [{:crypto, :strong_rand_bytes, 1}, {:erlang, :put, 2}]

  defp program({Delivery, :produce, 4}, [_, module, _, _], %{row: %{fault: fault}}, _) do
    tail = if fault in [:producer_error, :producer_raise], do: :invalid, else: :seal

    List.duplicate({Delivery, :"-produce/4-fun-0-", 1}, 2) ++
      [{module, :produce, 2}, {Delivery, tail, if(tail == :seal, do: 2, else: 0)}]
  end

  defp program({Delivery, :"-produce/4-fun-0-", 1}, _, _, _), do: []

  defp program({Delivery, :seal, 2}, [_, values], _, _) when not is_map(values),
    do: [{Delivery, :invalid, 0}]

  defp program({Delivery, :seal, 2}, [_, values], _, _) when map_size(values) != 2,
    do: [{Delivery, :"-seal/2-fun-0-", 1}]

  defp program({Delivery, :seal, 2}, _, _, _),
    do: [{Delivery, :ordered_values, 2}, {Delivery, :seal_to_entry, 2}]

  defp program({Delivery, :"-seal/2-fun-0-", 1}, _, _, _), do: [{Delivery, :invalid, 0}]

  defp program({Delivery, :seal_to_entry, 2}, _, _, _),
    do: [{Process, :get, 1}, {Envelope, :context, 4}, {Envelope, :seal, 3}, {:erlang, :put, 2}]

  defp program({Delivery, :ordered_values, 2}, _, _, _),
    do: List.duplicate({Delivery, :"-ordered_values/2-fun-0-", 3}, 2)

  defp program({Delivery, :"-ordered_values/2-fun-0-", 3}, _, _, _),
    do: [{Delivery, :deliverable, 1}]

  defp program({Delivery, :deliverable, 1}, _, _, _), do: [{Envelope, :max_value_bytes, 0}]
  defp program({Delivery, :complete, 2}, _, _, _), do: [{Delivery, :complete_entry, 3}]

  defp program({Delivery, :complete_current, 2}, _, _, _),
    do: [
      {Delivery, :reference, 1},
      {Delivery, :key, 1},
      {Process, :get, 1},
      {Delivery, :complete_entry, 3}
    ]

  defp program({Delivery, :complete_entry, 3}, _, _, _),
    do: [{Process, :get, 1}, {:erlang, :put, 2}]

  defp program({Delivery, f, 0}, _, _, _)
       when f in [:lost, :invalid, :refused, :in_transaction, :requires_call],
       do: [{AshOnetime.Error, :new, 2}]

  defp program({Delivery, :lost_class, 0}, _, _, _), do: :ordinary

  defp program({Envelope, :context, 4}, _, _, _),
    do: List.duplicate({Envelope, :"-context/4-fun-0-", 1}, 4)

  defp program({Envelope, f, _}, _, _, _)
       when f in [
              :max_value_bytes,
              :bound,
              :public_key,
              :split,
              :additional_data,
              :"-context/4-fun-0-",
              :"-seal/3-fun-0-",
              :"-seal/3-fun-1-"
            ],
       do: []

  defp program({Envelope, :seal, 3}, [_, values, _], _, _),
    do:
      List.duplicate({Envelope, :"-seal/3-fun-0-", 1}, length(values)) ++
        List.duplicate({Envelope, :"-seal/3-fun-1-", 1}, length(values)) ++
        [{Envelope, :encrypt, 3}]

  defp program({Envelope, :encrypt, 3}, _, _, _),
    do: [
      {Envelope, :public_key, 1},
      {:crypto, :generate_key, 2},
      {Envelope, :agree, 2},
      {Envelope, :derive, 4},
      {Envelope, :additional_data, 1},
      {:crypto, :crypto_one_time_aead, 7}
    ]

  defp program({Envelope, :open, 5}, _, _, _),
    do: [
      {Envelope, :bound, 1},
      {Envelope, :split, 2},
      {Envelope, :public_key, 1},
      {Envelope, :agree, 2},
      {Envelope, :derive, 4},
      {Envelope, :decrypt, 5},
      {Envelope, :decode, 3}
    ]

  defp program({Envelope, :agree, 2}, _, _, _), do: [{:crypto, :compute_key, 4}]
  defp program({Envelope, :derive, 4}, _, _, _), do: List.duplicate({Envelope, :hmac, 2}, 3)
  defp program({Envelope, :hmac, 2}, _, _, _), do: [{:crypto, :mac, 4}]

  defp program({Envelope, :decrypt, 5}, _, _, _),
    do: [{Envelope, :additional_data, 1}, {:crypto, :crypto_one_time_aead, 7}]

  defp program({Envelope, :decode, 3}, [<<>>, 0, _], _, _), do: []
  defp program({Envelope, :decode, 3}, _, _, _), do: [{Envelope, :decode, 3}]
  defp program(_, _, _, _), do: :ordinary

  defp returns(events, root, side, b) do
    returned =
      events
      |> Enum.filter(&(&1.index > root.index))
      |> Enum.find(fn e ->
        e.pid == root.pid and e.mfa == root.mfa and length(e.stack) == length(root.stack) + 1 and
          elem(e.event, 1) in [:return_from, :exception_from]
      end)

    expected = expected_return(root.mfa, arguments(root), side, b)

    case {returned, expected} do
      {%{event: {_, :exception_from, _, _}}, _} ->
        []

      {_, :paired} ->
        []

      {%{event: {_, :return_from, _, actual}} = e, {:value, actual}} ->
        # Pinning above is exact term equality, including binaries and environments.
        _ = e
        []

      {%{event: {_, _, _, actual}} = e, {:value, expected}} ->
        [difference(e, :permitted_return, actual, expected)]

      {nil, _} ->
        [difference(root, :missing_frame_return, :absent, expected)]
    end
  end

  defp expected_return({Delivery, f, _}, _, _, b) when f in [:armed_call, :armed, :finish],
    do: bound_return(b, :delivered_return)

  defp expected_return({AshOnetime, :deliver, _}, _, _, b), do: bound_return(b, :delivered_return)
  defp expected_return({Delivery, :deliver, 2}, _, _, b), do: bound_return(b, :delivered_return)
  defp expected_return({Delivery, :dispatch, 2}, _, _, b), do: {:value, b[:raw_return]}

  defp expected_return({Delivery, :"-armed/4-fun-0-", 7}, _, side, _),
    do: {:value, {:ok, Returns.delivery(side.row, side.values)}}

  defp expected_return({Delivery, :open, 7}, _, side, _),
    do: {:value, {:ok, Returns.delivery(side.row, side.values)}}

  defp expected_return({Delivery, f, _}, _, %{row: %{branch: :producer_failure}}, _)
       when f in [:produce, :seal],
       do: {:value, {:error, AshOnetime.Test.ExitBoundary.FailureTwins.error(:producer_failure)}}

  defp expected_return({Delivery, f, _}, _, _, _)
       when f in [:produce, :seal, :seal_to_entry, :complete, :complete_entry, :complete_current],
       do: {:value, :ok}

  defp expected_return(
         {Delivery, :"-ordered_values/2-fun-0-", 3},
         [name, {:ok, prior}, values],
         _,
         _
       ),
       do: {:value, {:cont, {:ok, [Map.fetch!(values, name) | prior]}}}

  defp expected_return({Delivery, :"-produce/4-fun-0-", 1}, [{_, value}], _, _),
    do: {:value, is_nil(value)}

  defp expected_return({Delivery, :key, 1}, [ref], _, _),
    do: {:value, {Delivery, :crypto.hash(:sha256, ref)}}

  defp expected_return({Delivery, :protection, 1}, _, side, _),
    do: {:value, {:ok, side.protection}}

  defp expected_return({Delivery, f, _}, _, _, _) when f in [:subject_type?, :built_for_action?],
    do: {:value, true}

  defp expected_return({Delivery, f, _}, _, _, _)
       when f in [:bulk?, :task_route?, :"-bulk?/1-fun-0-"], do: {:value, false}

  defp expected_return({Delivery, :route, 2}, _, %{row: %{branch: :transaction}}, _), do: :paired
  defp expected_return({Delivery, :route, 2}, _, _, _), do: {:value, :ok}
  defp expected_return({Delivery, :cell, 1}, _, _, b), do: {:value, {:ok, b.cell}}

  defp expected_return({Delivery, :put_private, 3}, [subject, name, value], _, _) do
    context = Map.update(subject.context, :private, %{name => value}, &Map.put(&1, name, value))
    {:value, %{subject | context: context}}
  end

  defp expected_return({Delivery, :put_reference, 2}, [subject, ref], side, b),
    do:
      expected_return(
        {Delivery, :put_private, 3},
        [subject, :ash_onetime_delivery, %{ref: ref}],
        side,
        b
      )

  defp expected_return({Delivery, :put_cell, 1}, [subject], side, b) do
    {:value, built} =
      expected_return(
        {Delivery, :put_private, 3},
        [subject, :ash_onetime_delivery_cell, b.cell],
        side,
        b
      )

    {:value, {built, b.cell}}
  end

  defp expected_return({Delivery, :reference, 1}, [subject], _, _),
    do:
      {:value,
       case get_in(subject.context, [:private, :ash_onetime_delivery, :ref]) do
         nil -> :error
         ref -> {:ok, ref}
       end}

  defp expected_return({Delivery, :claim, 3}, _, %{row: %{branch: :direct}}, _), do: :paired

  defp expected_return({Delivery, f, _}, _, side, b) when f in [:claim, :claim_entry],
    do: {:value, {:ok, PermittedTrace.handle(b, side)}}

  defp expected_return({Delivery, :deliverable, 1}, [{:ok, value}], _, _),
    do: {:value, {:ok, value}}

  defp expected_return({Delivery, :ordered_values, 2}, [names, values], _, _),
    do: {:value, {:ok, Enum.map(names, &Map.fetch!(values, &1))}}

  defp expected_return({Delivery, :normalize, 3}, [raw, type, opts], _, _) do
    result = Returns.delivered(raw, type, opts, :delivery)

    {:value,
     if(match?({:error, _}, result),
       do: result,
       else: Tuple.delete_at(result, tuple_size(result) - 1)
     )}
  end

  defp expected_return({Envelope, :context, 4}, args, _, _),
    do: {:value, apply(Envelope, :context, args)}

  defp expected_return({Envelope, :"-context/4-fun-0-", 1}, [part], _, _),
    do: {:value, <<byte_size(part)::16, part::binary>>}

  defp expected_return({Envelope, :"-seal/3-fun-0-", 1}, [_], _, _), do: {:value, true}

  defp expected_return({Envelope, :"-seal/3-fun-1-", 1}, [value], _, _),
    do: {:value, <<byte_size(value)::32, value::binary>>}

  defp expected_return({Envelope, f, 3}, _, _, b) when f in [:seal, :encrypt],
    do: {:value, {:ok, <<1, b.epk::binary, b.tag::binary, b.ct::binary>>}}

  defp expected_return({Envelope, :derive, 4}, _, _, b),
    do: {:value, AshOnetime.Test.ExitBoundary.FrameBindings.derived_key(b)}

  defp expected_return({Envelope, :hmac, 2}, [key, data], _, _),
    do: {:value, :crypto.mac(:hmac, :sha256, key, data)}

  defp expected_return({Envelope, :max_value_bytes, 0}, _, _, _), do: {:value, 65_536}
  defp expected_return({Envelope, :bound, 1}, [count], _, _), do: {:value, count * 65_540}

  defp expected_return({Envelope, :additional_data, 1}, [context], _, _),
    do: {:value, <<1, context::binary>>}

  defp expected_return({Envelope, :split, 2}, _, _, b), do: {:value, {:ok, b.epk, b.tag, b.ct}}
  defp expected_return({Envelope, :public_key, 1}, _, _, _), do: {:value, :ok}
  defp expected_return({Envelope, :agree, 2}, _, _, b), do: {:value, {:ok, b.shared}}

  defp expected_return({Envelope, :decrypt, 5}, _, side, _),
    do: {:value, {:ok, plaintext(side.values)}}

  defp expected_return({Envelope, :open, 5}, _, side, _),
    do: {:value, {:ok, ordered(side.values)}}

  defp expected_return({Envelope, :decode, 3}, _, side, _),
    do: {:value, {:ok, ordered(side.values)}}

  defp expected_return(_, _, _, _), do: :paired

  defp bound_return(b, key) do
    case Map.fetch(b, key) do
      {:ok, value} -> {:value, value}
      :error -> :paired
    end
  end

  defp ordered(values), do: [values.short, values.long]

  defp plaintext(values),
    do: for(v <- ordered(values), into: <<>>, do: <<byte_size(v)::32, v::binary>>)

  defp difference(e, rule, actual, expected),
    do: %{
      rule: rule,
      index: e.index,
      at: Map.take(e, [:mfa, :role, :phase, :stack]),
      actual: actual,
      expected: expected
    }
end
