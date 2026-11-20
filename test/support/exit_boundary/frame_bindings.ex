defmodule AshOnetime.Test.ExitBoundary.FrameBindings do
  @moduledoc false
  alias AshOnetime.Delivery
  alias AshOnetime.Delivery.Envelope
  alias AshOnetime.Test.ExitBoundary.{Compiled, PermittedTrace}

  def check(side, events, b) do
    events
    |> Enum.filter(&(elem(&1.event, 1) == :call and PermittedTrace.frame?(&1.mfa)))
    |> Enum.flat_map(fn node ->
      args = arguments(node)
      expected = arguments(node, side, events, b)

      if expected == :entry or args === expected,
        do: [],
        else: [difference(node, :permitted_arguments, args, expected)]
    end)
  end

  defp arguments(%{event: {_, :call, {_, _, args}}}), do: args

  defp arguments(%{mfa: {AshOnetime, :deliver, 1}} = e, _, events, _) do
    [_, input] = parent_arguments(e, events)
    [input.built]
  end

  defp arguments(%{mfa: {AshOnetime, :deliver, 2}}, _, _, _), do: :entry

  defp arguments(%{mfa: {Delivery, :deliver, 2}} = e, _, events, _),
    do: parent_arguments(e, events)

  defp arguments(%{mfa: {Delivery, f, 1}} = e, _, events, _)
       when f in [:protection, :cell, :bulk?, :built_for_action?],
       do: [hd(parent_arguments(e, events))]

  defp arguments(%{mfa: {Delivery, :subject_type?, 2}} = e, _, events, _) do
    [subject] = parent_arguments(e, events)
    [subject, subject.action.type]
  end

  defp arguments(%{mfa: {Delivery, f, 2}} = e, _, events, _) when f in [:route, :task_route?],
    do: parent_arguments(e, events)

  defp arguments(%{mfa: {Delivery, :"-bulk?/1-fun-0-", 2}} = e, _, events, _) do
    [subject] = ancestor_arguments(e, events, {Delivery, :bulk?, 1})
    n = ordinal(e, events)
    [Enum.fetch!([:bulk_create, :bulk_update, :bulk_destroy], n), subject.context]
  end

  defp arguments(%{mfa: {Delivery, :put_cell, 1}} = e, _, events, _),
    do: [hd(parent_arguments(e, events))]

  defp arguments(%{mfa: {Delivery, :armed_call, 4}} = e, side, events, b) do
    [subject, opts] = parent_arguments(e, events)
    [subject, side.protection, b.cell, opts]
  end

  defp arguments(%{mfa: {Delivery, :armed, 4}} = e, side, events, b) do
    [subject, _, _, opts] = parent_arguments(e, events)
    [subject, side.protection, {b.key, b.ref, b.sk, b.pk}, opts]
  end

  defp arguments(%{mfa: {Delivery, :put_reference, 2}} = e, _, events, b),
    do: [hd(parent_arguments(e, events)), b.ref]

  defp arguments(%{mfa: {Delivery, :put_private, 3}} = e, _, events, b) do
    case parent(e, events) do
      %{mfa: {Delivery, :put_cell, 1}} = p ->
        [hd(arguments(p)), :ash_onetime_delivery_cell, b.cell]

      %{mfa: {Delivery, :put_reference, 2}} = p ->
        [hd(arguments(p)), :ash_onetime_delivery, %{ref: b.ref}]
    end
  end

  defp arguments(%{mfa: {Delivery, :dispatch, 2}} = e, _, events, _b) do
    [_, _, _, opts] = parent_arguments(e, events)
    [result_before(e, events, {Delivery, :put_reference, 2}), opts]
  end

  defp arguments(%{mfa: {Delivery, :normalize, 3}} = e, side, events, _) do
    [_, _, _, opts] = parent_arguments(e, events)
    [result_before(e, events, {Delivery, :dispatch, 2}), side.row.type, opts]
  end

  defp arguments(%{mfa: {Delivery, :finish, 2}} = e, side, events, b) do
    [result_before(e, events, {Delivery, :normalize, 3}), open_closure(e, side, b)]
  end

  defp arguments(%{mfa: {Delivery, :"-armed/4-fun-0-", 7}}, side, _, b),
    do: open_environment(side, b)

  defp arguments(%{mfa: {Delivery, :open, 7}}, side, _, b), do: open_arguments(side, b)
  defp arguments(%{mfa: {Delivery, :key, 1}}, _, _, b), do: [b.ref]

  defp arguments(%{mfa: {Delivery, :reference, 1}} = e, _, events, _),
    do: [hd(parent_arguments(e, events))]

  defp arguments(%{mfa: {Delivery, :claim, 3}} = e, side, events, b),
    do: [hd(parent_arguments(e, events)), b[:cell], side.protection.executing_only]

  defp arguments(%{mfa: {Delivery, :"-claim/3-fun-0-", 1}}, _, _, _), do: [:error]

  defp arguments(%{mfa: {Delivery, :claim_entry, 6}} = e, side, events, b) do
    [subject, cell, names] = parent_arguments(e, events)

    [
      {:armed, e.pid, side.resource, side.row.action, cell, b.pk},
      b.key,
      b.ref,
      subject,
      cell,
      names
    ]
  end

  defp arguments(%{mfa: {Delivery, :produce, 4}} = e, side, events, b) do
    [subject, _, _, _] = parent_arguments(e, events)
    trusted = result_before(e, events, {AshOnetime.Admission, :trusted_context, 1})
    [PermittedTrace.handle(b, side), side.protection.produce, subject, trusted]
  end

  defp arguments(%{mfa: {Delivery, :"-produce/4-fun-0-", 1}} = e, _, events, _) do
    [_, _, _, trusted] = ancestor_arguments(e, events, {Delivery, :produce, 4})
    [trusted |> Map.take([:actor, :tenant]) |> Map.to_list() |> Enum.fetch!(ordinal(e, events))]
  end

  defp arguments(%{mfa: {Delivery, :seal, 2}}, side, _, b),
    do: [PermittedTrace.handle(b, side), b[:values]]

  defp arguments(%{mfa: {Delivery, :"-seal/2-fun-0-", 1}}, _, _, _), do: [false]

  defp arguments(%{mfa: {Delivery, :ordered_values, 2}}, side, _, b),
    do: [side.protection.executing_only, b.values]

  defp arguments(%{mfa: {Delivery, :"-ordered_values/2-fun-0-", 3}} = e, side, events, b) do
    n = ordinal(e, events)

    prior =
      Enum.take(side.protection.executing_only, n)
      |> Enum.map(&Map.fetch!(b.values, &1))
      |> Enum.reverse()

    [Enum.fetch!(side.protection.executing_only, n), {:ok, prior}, b.values]
  end

  defp arguments(%{mfa: {Delivery, :deliverable, 1}} = e, _, events, _) do
    [name, _, values] = parent_arguments(e, events)
    [Map.fetch(values, name)]
  end

  defp arguments(%{mfa: {Delivery, :seal_to_entry, 2}}, side, _, b),
    do: [PermittedTrace.handle(b, side), ordered(b.values)]

  defp arguments(%{mfa: {Delivery, :complete, 2}} = e, side, events, b),
    do: [PermittedTrace.handle(b, side), admission_state(e, events)]

  defp arguments(%{mfa: {Delivery, :complete_current, 2}} = e, _, events, _),
    do: [Enum.at(parent_arguments(e, events), 1), admission_state(e, events)]

  defp arguments(%{mfa: {Delivery, :complete_entry, 3}} = e, _, events, b),
    do: [b.key, Map.get(b, :inv, :missing_bound_inv), admission_state(e, events)]

  defp arguments(%{mfa: {Delivery, f, 0}}, _, _, _)
       when f in [:lost, :invalid, :refused, :in_transaction, :requires_call, :lost_class], do: []

  defp arguments(%{mfa: {Envelope, :context, 4}}, side, _, b),
    do: [b.ref, Map.get(b, :inv, :missing_bound_inv), side.resource, side.row.action]

  defp arguments(%{mfa: {Envelope, :"-context/4-fun-0-", 1}} = e, side, events, b),
    do: [
      Enum.fetch!(
        [b.ref, Map.get(b, :inv, :missing_bound_inv), Atom.to_string(side.resource), Atom.to_string(side.row.action)],
        ordinal(e, events)
      )
    ]

  defp arguments(%{mfa: {Envelope, :seal, 3}}, _, _, b), do: [b.pk, ordered(b.values), b.context]

  defp arguments(%{mfa: {Envelope, f, 1}} = e, _, events, b)
       when f in [:"-seal/3-fun-0-", :"-seal/3-fun-1-"],
       do: [Enum.fetch!(ordered(b.values), ordinal(e, events))]

  defp arguments(%{mfa: {Envelope, :encrypt, 3}}, _, _, b),
    do: [b.pk, plaintext(b.values), b.context]

  defp arguments(%{mfa: {Envelope, :open, 5}}, _, _, b),
    do: [b.envelope, b.sk, b.pk, 2, b.context]

  defp arguments(%{mfa: {Envelope, :bound, 1}}, _, _, _), do: [2]
  defp arguments(%{mfa: {Envelope, :split, 2}}, _, _, b), do: [b.envelope, 131_080]

  defp arguments(%{mfa: {Envelope, :public_key, 1}} = e, _, _, b),
    do: [if({Envelope, :encrypt, 3} in e.stack, do: b.pk, else: b.epk)]

  defp arguments(%{mfa: {Envelope, :agree, 2}} = e, _, _, b),
    do: if({Envelope, :encrypt, 3} in e.stack, do: [b.pk, b.esk], else: [b.epk, b.sk])

  defp arguments(%{mfa: {Envelope, :derive, 4}}, _, _, b), do: [b.shared, b.epk, b.pk, b.context]

  defp arguments(%{mfa: {Envelope, :hmac, 2}} = e, _, events, b),
    do: Enum.fetch!(hmac_inputs(b), ordinal(e, events)) |> Tuple.to_list()

  defp arguments(%{mfa: {Envelope, :additional_data, 1}}, _, _, b), do: [b.context]

  defp arguments(%{mfa: {Envelope, :decrypt, 5}}, _, _, b) do
    {key, nonce} = derived_key(b)
    [key, nonce, b.ct, b.tag, b.context]
  end

  defp arguments(%{mfa: {Envelope, :decode, 3}} = e, _, _events, b) do
    n = Enum.count(e.stack, &(&1 == {Envelope, :decode, 3}))
    values = ordered(b.values)
    [plaintext_list(Enum.drop(values, n)), 2 - n, Enum.take(values, n) |> Enum.reverse()]
  end

  defp arguments(%{mfa: {Envelope, :max_value_bytes, 0}}, _, _, _), do: []
  defp arguments(e, _, _, _), do: {:undeclared_frame, e.mfa}

  defp admission_state(e, events) do
    {:ok, state} = result_before(e, events, {AshOnetime.Admission, :state, 1})
    state
  end

  defp open_arguments(side, b),
    do: [b.key, b.ref, b.sk, b.pk, side.protection, side.resource, side.row.action]

  defp open_environment(side, b),
    do: Compiled.closure_environment(Delivery, :armed, 4, :open, open_arguments(side, b))

  defp open_closure(e, side, b) do
    [_, actual] = arguments(e)
    info = Map.new(Function.info(actual))
    expected = {Compiled.identity(Delivery, :"-armed/4-fun-0-", 0), open_environment(side, b)}
    observed = {{info.module, info.name, info.arity, info.new_uniq, info.index}, info.env}
    if observed === expected, do: actual, else: {:invalid_open_closure, expected}
  end

  def hmac_inputs(b) do
    salt = b.epk <> b.pk
    prk = :crypto.mac(:hmac, :sha256, salt, b.shared)
    info = "ash_onetime delivery v1" <> b.context
    first = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    [{salt, b.shared}, {prk, info <> <<1>>}, {prk, first <> info <> <<2>>}]
  end

  def derived_key(b) do
    [_, {prk, a}, {prk, c}] = hmac_inputs(b)

    <<key::32-binary, nonce::12-binary, _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, a) <> :crypto.mac(:hmac, :sha256, prk, c)

    {key, nonce}
  end

  defp ordered(values), do: [values.short, values.long]
  defp plaintext(values), do: plaintext_list(ordered(values))

  defp plaintext_list(values),
    do: for(v <- values, into: <<>>, do: <<byte_size(v)::32, v::binary>>)

  defp parent(e, events),
    do:
      previous(e, events, fn p ->
        elem(p.event, 1) == :call and p.mfa == hd(e.stack) and p.stack == tl(e.stack)
      end)

  defp parent_arguments(e, events), do: parent(e, events) |> arguments()

  defp ancestor_arguments(e, events, mfa),
    do: previous(e, events, &(&1.mfa == mfa and elem(&1.event, 1) == :call)) |> arguments()

  defp result_before(e, events, mfa),
    do:
      previous(e, events, &(&1.mfa == mfa and elem(&1.event, 1) == :return_from)).event |> elem(3)

  defp previous(e, events, predicate),
    do:
      events
      |> Enum.filter(&(&1.index < e.index))
      |> Enum.reverse()
      |> Enum.find(&(&1.pid == e.pid and predicate.(&1)))

  defp ordinal(e, events) do
    start = parent(e, events).index

    events
    |> Enum.filter(&(&1.index > start and &1.index < e.index))
    |> Enum.count(
      &(&1.pid == e.pid and &1.mfa == e.mfa and &1.stack == e.stack and
          elem(&1.event, 1) == :call)
    )
  end

  defp difference(e, rule, actual, expected),
    do: %{
      rule: rule,
      index: e.index,
      at: Map.take(e, [:mfa, :role, :phase, :stack]),
      actual: actual,
      expected: expected
    }
end
