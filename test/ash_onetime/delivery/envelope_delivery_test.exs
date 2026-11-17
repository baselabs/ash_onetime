defmodule AshOnetime.Delivery.EnvelopeDeliveryTest do
  # The envelope negatives end to end (§2.7.3): on every route, a real `deliver/2` call
  # whose envelope is tampered with after the action committed returns
  # `:executing_only_lost` with no value and no exception, and a retry under the same key
  # replays with no value. A low-order recipient key is refused before sealing: the
  # action rolls back, and a retry executes once.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery
  alias AshOnetime.Delivery.Envelope

  @max Envelope.max_value_bytes()
  @captured {__MODULE__, :captured}

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)
  end

  @tampers [
    version: {:flip, 0},
    pk_e: {:flip, 1},
    tag: {:flip, 33},
    ciphertext: {:flip, 49},
    truncated_empty: {:truncate, 0},
    truncated_header: {:truncate, 48},
    truncated_tag: {:truncate, 49},
    truncated_last: {:truncate, -1},
    trailing_byte: :trailing,
    inv_field: :inv,
    count_over: {:plaintext, :over},
    count_under: {:plaintext, :under},
    size_over: {:plaintext, :size},
    total_over_bound: {:plaintext, :bound}
  ]

  for route <- [:create, :update, :destroy, :soft_destroy, :generic],
      {name, tamper} <- @tampers do
    @route route
    @tamper tamper

    @tag executing_only_envelope: name
    test "#{name} on #{route}: lost after commit, then a replay with no value", %{
      prefix: prefix
    } do
      build = builder(prefix, @route, unique_key("envelope-#{@route}"))

      first =
        build.() |> capture_public() |> tamper_after_completion(@tamper) |> AshOnetime.deliver()

      assert error_code(first) == :executing_only_lost
      assert claim_count(prefix) == 1

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :replayed, values: values} = delivery(retry)
      assert values == %{}

      assert_at_most_one_value([first, retry])
      refute_residue()
    end
  end

  for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
    @route route

    @tag executing_only_envelope: :low_order
    test "a low-order recipient key on #{route} is refused before sealing", %{prefix: prefix} do
      build = builder(prefix, @route, unique_key("low-order-#{@route}"))

      first =
        build.()
        |> hook(
          :before_transaction,
          fn subject ->
            key = entry_key(subject)
            {:armed, pid, resource, action, cell, _public} = Process.get(key)
            Process.put(key, {:armed, pid, resource, action, cell, <<0::256>>})
            subject
          end,
          []
        )
        |> AshOnetime.deliver()

      assert error_code(first) == :executing_only_lost
      assert claim_count(prefix) == 0

      retry = AshOnetime.deliver(build.())
      assert %Delivery{outcome: :executed, values: %{secret: secret}} = delivery(retry)
      assert byte_size(secret) == 32

      assert_at_most_one_value([first, retry])
      refute_residue()
    end
  end

  # The recipient key, read from the armed entry before the action runs, so a forged
  # plaintext can be sealed with an authentic tag: the decoder's checks, not the tag,
  # must refuse it.
  defp capture_public(subject) do
    hook(
      subject,
      :before_transaction,
      fn subject ->
        {:armed, _pid, _resource, _action, _cell, public} = Process.get(entry_key(subject))
        Process.put(@captured, public)
        subject
      end,
      []
    )
  end

  # Rewrites the completed entry once the package's entry has completed: through an
  # around-action outside the package's for CRUD, an after-action after the package's
  # for a generic action.
  defp tamper_after_completion(%Ash.Changeset{} = changeset, tamper) do
    hook(
      changeset,
      :around_action,
      fn changeset, callback ->
        result = callback.(changeset)
        rewrite(entry_key(changeset), changeset, tamper)
        result
      end,
      prepend?: true
    )
  end

  defp tamper_after_completion(%Ash.ActionInput{} = input, tamper) do
    hook(
      input,
      :after_action,
      fn input, result ->
        rewrite(entry_key(input), input, tamper)
        {:ok, result}
      end,
      []
    )
  end

  defp rewrite(key, subject, tamper) do
    {:done, inv, :executed, envelope, committed} = Process.get(key)
    {inv, envelope} = tampered(tamper, inv, envelope, subject)
    Process.put(key, {:done, inv, :executed, envelope, committed})
  end

  defp tampered({:flip, byte}, inv, envelope, _subject), do: {inv, flip(envelope, byte)}

  defp tampered({:truncate, length}, inv, envelope, _subject) when length < 0,
    do: {inv, binary_part(envelope, 0, byte_size(envelope) + length)}

  defp tampered({:truncate, length}, inv, envelope, _subject),
    do: {inv, binary_part(envelope, 0, length)}

  defp tampered(:trailing, inv, envelope, _subject), do: {inv, envelope <> <<0>>}
  defp tampered(:inv, inv, envelope, _subject), do: {flip(inv, 0), envelope}

  defp tampered({:plaintext, shape}, inv, _envelope, subject) do
    %{ref: ref} = subject.context.private.ash_onetime_delivery
    context = Envelope.context(ref, inv, subject.resource, subject.action.name)
    {:ok, envelope} = Envelope.encrypt(Process.delete(@captured), plaintext(shape), context)
    {inv, envelope}
  end

  defp plaintext(:over), do: encode([:crypto.strong_rand_bytes(32), "extra"])
  defp plaintext(:under), do: <<>>
  defp plaintext(:size), do: <<@max + 1::32>>
  defp plaintext(:bound), do: <<@max::32, :binary.copy(<<1>>, @max)::binary, 0>>

  defp encode(values), do: Enum.map_join(values, &<<byte_size(&1)::32, &1::binary>>)

  defp flip(binary, byte) do
    <<head::binary-size(^byte), target, tail::binary>> = binary
    <<head::binary, Bitwise.bxor(target, 1), tail::binary>>
  end

  defp entry_key(subject),
    do: Delivery.key(subject.context.private.ash_onetime_delivery.ref)

  defp delivery(result) when is_tuple(result) and tuple_size(result) > 2,
    do: elem(result, tuple_size(result) - 1)

  defp delivery(_result), do: nil

  defp refute_residue do
    refute Enum.any?(Process.get_keys(), &match?({Delivery, _}, &1))
    Process.delete(@captured)
  end
end
