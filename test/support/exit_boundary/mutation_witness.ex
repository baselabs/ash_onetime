defmodule AshOnetime.Test.ExitBoundary.MutationWitness do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Delivery.Envelope

  alias AshOnetime.Test.ExitBoundary.{
    Hold,
    Origins,
    Producer,
    TransportReferences,
    Wire
  }

  # A failure in the same function is insufficient. Match the native occurrence
  # and its changed argument/return against the independently bound sources.
  def named?(mutation, first, pair, comparison) do
    with %{at: %{mfa: mfa, run_index: index}} <- first,
         true <- mfa == mutation.first,
         true <- is_integer(index),
         indexed <- Origins.build(pair.run),
         %{role: role} = event <- Enum.find(indexed.events, &(&1.index == index)),
         true <- role == :caller or mutation.id in [:r25, :r26],
         true <-
           location(
             mutation.id,
             event,
             Enum.filter(indexed.events, &(&1.index <= index)),
             comparison.bindings,
             first
           ) do
      true
    else
      _ -> false
    end
  end

  defp location(
         :r_iso_k,
         %{event: {_, :return_from, {Delivery, :key, 1}, key}},
         _,
         b,
         %{rule: :permitted_return}
       ),
       do: key !== {Delivery, :crypto.hash(:sha256, b.ref)}

  defp location(
         :r_iso_inv,
         %{event: {_, :call, {:erlang, :put, [key, {:claimed, inv, public}]}}},
         _,
         b,
         %{rule: :dictionary_binding}
       ),
       do: key === b.key and public === b.pk and inv !== b.inv

  defp location(
         :r_iso_return,
         %{event: {_, :return_from, {AshOnetime, :deliver, 2}, {:ok, result, %Delivery{}}}},
         _,
         b,
         %{rule: rule}
       )
       when rule in [:return, :permitted_return],
       do: result.amount === rem(byte_size(b.values.long), 2) and {:ok, result} !== b.raw_return

  defp location(
         :r_iso_o2,
         %{event: {_, :return_from, {AshOnetime.Admission, :prepare_resolved, 2}, {:ok, state}}},
         _,
         b,
         %{rule: :o2_uuid}
       ),
       do: state.request.id === b.built_subject.data.id

  defp location(
         :r_iso_o4,
         %{event: {_, :call, {AshOnetime.Store.Postgres, :query_claim, [_, _, parameters, :idempotency]}}},
         _,
         b,
         %{path: [:event, 2, 2, 2, 6]}
       ),
       do: Enum.at(parameters, 6) == 3_600 + 1 + rem(:binary.first(b.c_admit.id), 2)

  defp location(:r1, %{event: {_, :call, {:erlang, :put, [:m, 0]}}}, events, b, _),
    do: after_seal?(events, b)

  defp location(
         :r2,
         %{event: {_, :call, {:erlang, :put, [key, {:sealed, inv, envelope}]}}},
         _,
         b,
         _
       ),
       do: key !== b.key and inv === b.inv and envelope === b.envelope

  defp location(
         id,
         %{event: {_, :call, {:erlang, :put, [key, {:sealed, inv, envelope}]}}},
         _,
         b,
         _
       )
       when id in [:r3, :r_set_len, :r_set_bit, :r_set_par],
       do: key === b.key and inv !== b.inv and envelope === b.envelope

  defp location(
         :r4,
         %{
           event:
             {_, :call, {:erlang, :put, [key, {:done, inv, :executed, envelope, completion}]}}
         },
         _,
         b,
         _
       ),
       do: {key, inv, envelope} === {b.key, b.inv, b.envelope} and completion !== b.completion

  defp location(
         :r5,
         %{event: {_, :call, {:crypto, :generate_key, [:ecdh, :x25519, _]}}},
         _,
         _,
         _
       ),
       do: true

  defp location(
         :r6,
         %{event: {_, :call, {:crypto, :crypto_one_time_aead, [_, _, _, _, aad, _, true]}}},
         _,
         b,
         %{rule: :aead_aad}
       ),
       do: aad !== <<1, b.context::binary>>

  defp location(:r7, %{event: {_, :return_from, {Envelope, :seal, 3}, {:ok, envelope}}}, _, b, %{
         rule: :crypto_envelope
       }),
       do: envelope !== <<1, b.epk::binary, b.tag::binary, b.ct::binary>>

  defp location(
         :r8,
         %{event: {_, :return_from, {:erlang, :get, 0}, dictionary}, stack: stack},
         _,
         b,
         _
       ),
       do:
         {AshOnetime.Change, :complete, 2} in stack and
           Enum.any?(dictionary, fn
             {key, {:sealed, inv, envelope}} ->
               {key, inv, envelope} === {b.key, b.inv, b.envelope}

             _ ->
               false
           end)

  defp location(
         :r_iso_context,
         %{event: {_, :call, {AshOnetime.Admission, :dispatch_reservation, [subject | _]}}},
         _,
         b,
         %{rule: :context}
       ),
       do:
         get_in(subject.context, [:private, :ash_onetime_delivery]) ===
           %{ref: b.ref, n: rem(:binary.first(b.ref), 2)}

  defp location(:r9, %{index: index, event: {_, :call, {Producer, :produce, _}}}, events, b, _),
    do:
      Enum.count(
        events,
        &(&1.index <= index and match?(%{event: {_, :call, {Producer, :produce, _}}}, &1))
      ) == 2 and
        after_seal?(Enum.filter(events, &(&1.index < index)), b)

  defp location(
         :r10,
         %{
           event:
             {_, :call, {AshOnetime.Admission, :dispatch_reservation, [_, _, _, %{names: names}]}}
         },
         _,
         _,
         %{rule: :claim, path: [:args, 3]}
       ),
       do: names == [:long, :short]

  defp location(
         :r11,
         %{event: {_, :call, {Process, :get, [key]}}},
         _,
         b,
         _
       ),
       do: key === b.key

  defp location(
         :r_iso_o3,
         %{event: {_, :call, {AshOnetime.Telemetry, :external_recovery, _}}},
         _,
         _,
         %{rule: :o3}
       ),
       do: true

  defp location(
         id,
         %{event: {_, :return_from, {:erlang, :get, 0}, dictionary}, stack: stack},
         _,
         b,
         %{rule: :o5}
       ) when id in [:r12, :r13, :r15] do
    source =
      case id do
        :r12 -> {AshOnetime.Cache, :store, 3}
        :r13 -> {AshOnetime.Store.Postgres, :update_complete, 7}
        :r15 -> {AshOnetime.Admission, :hold_reference, 2}
      end

    source in stack and
      Enum.any?(dictionary, fn
        {key, {:sealed, inv, envelope}} -> {key, inv, envelope} === {b.key, b.inv, b.envelope}
        _ -> false
      end)
  end

  defp location(
         id,
         %{event: {_, :call, {Envelope, :context, args}}, stack: stack},
         _,
         b,
         %{rule: :permitted_call_order, twin: {AshOnetime.Store, :committed_completion, 2}}
       )
       when id in [:r14, :r_iso_order],
       do: {Delivery, :open, 7} in stack and Enum.take(args, 2) === [b.ref, b.inv]

  defp location(:r16, %{event: {_, :exception_from, {Delivery, :armed_call, 4}, _}}, _, _, _),
    do: true

  defp location(:r17, %{event: {_, :call, {Delivery, :normalize, [raw, _, _]}}}, _, _, %{
         path: [:return, :raw | _]
       }),
       do: match?({:error, _}, raw)

  defp location(
         :r18,
         %{
           index: index,
           event: {_, :call, {:erlang, :put, [key, {:done, inv, :executed, envelope, nil}]}}
         },
         events,
         b,
         _
       ),
       do:
         {key, inv, envelope} === {b.key, b.inv, b.envelope} and
           Enum.any?(
             events,
             &(&1.index < index and &1.event == {&1.pid, :call, {:erlang, :erase, [b.key]}})
           )

  defp location(:r19, %{event: {_, :call, {:erlang, :put, [key, tuple]}}}, _, b, %{
         rule: :dictionary_binding
       })
       when is_tuple(tuple),
       do: key === b.key and tuple_size(tuple) == 6 and elem(tuple, 0) == :done

  defp location(
         :r20,
         %{event: {_, :call, {:erlang, :put, [:"$logger_metadata$", metadata]}}},
         _,
         _,
         _
       ),
       do: Map.has_key?(Map.new(metadata), :m)

  defp location(:r21, %{event: {_, :call, {:erlang, :spawn_opt, _}}}, _, _, _), do: true

  defp location(:r22, %{event: {_, :call, {Hold, :reference, [_, metadata]}}}, _, _, _),
    do: Map.has_key?(metadata, :m)

  defp location(
         :r23,
         %{event: {_, :call, {:erlang, :put, [key, {:done, inv, :replayed, envelope, nil}]}}},
         _,
         b,
         %{rule: :dictionary_binding}
       ),
       do: {key, inv, envelope} === {b.key, b.inv, b.envelope}

  defp location(
         :r24,
         %{event: {_, :call, {AshOnetime.Store, :committed_completion, [target, claim]}}},
         _,
         b,
         %{rule: :committed_readback_binding}
       ),
       do: target === b.target and claim.id !== b.c_admit.id

  defp location(:r25, event, events, b, _),
    do:
      wire_column?(event, events, fn
        {:bind_column, 9, _oid, _format, value} ->
          value === Integer.to_string(rem(byte_size(b.envelope), 2))

        _ ->
          false
      end)

  defp location(:r26, event, events, b, _),
    do:
      wire_column?(event, events, fn
        {:bind_column, 4, _oid, _format, value} -> value === b.envelope
        _ -> false
      end)

  defp location(:r27, %{event: {_, :call, {:erlang, :send, [_, {:m20, envelope}]}}}, _, b, _),
    do: envelope === b.envelope

  defp location(:r28, %{event: {_, :call, {:erlang, :port_set_data, [port, envelope]}}}, _, b, _),
    do: is_port(port) and envelope === b.envelope

  defp location(
         :r29,
         %{event: {_, :call, {:erlang, :monitor, [:process, _, [tag: envelope]]}}},
         _,
         b,
         _
       ),
       do: envelope === b.envelope

  defp location(_, _, _, _, _), do: false

  defp after_seal?(events, b),
    do:
      Enum.any?(events, fn
        %{event: {_, :call, {:erlang, :put, [key, {:sealed, inv, envelope}]}}} ->
          {key, inv, envelope} === {b.key, b.inv, b.envelope}

        _ ->
          false
      end)

  defp wire_column?(event, events, predicate) do
    indexed = %{events: events}
    transformed = indexed |> TransportReferences.build() |> Wire.build()

    case Enum.find(transformed, &(&1.index == event.index)) do
      nil -> false
      e -> contains?(e.event, predicate)
    end
  end

  defp contains?(value, predicate) do
    predicate.(value) or
      cond do
        is_tuple(value) ->
          value |> Tuple.to_list() |> Enum.any?(&contains?(&1, predicate))

        is_map(value) ->
          value |> Map.to_list() |> Enum.any?(&contains?(&1, predicate))

        match?([_ | _], value) ->
          [head | tail] = value
          contains?(head, predicate) or contains?(tail, predicate)

        true ->
          false
      end
  end
end
