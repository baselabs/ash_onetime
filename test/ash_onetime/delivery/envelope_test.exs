defmodule AshOnetime.Delivery.EnvelopeTest do
  # The envelope's negative probes (§2.7.3). Each tampered or malformed envelope is
  # refused with its own internal reason and no exception, so every check is observable
  # on its own; `deliver/2` maps every refusal to `:executing_only_lost`, which
  # `EnvelopeDeliveryTest` asserts end to end.
  use ExUnit.Case, async: true

  alias AshOnetime.Delivery.Envelope

  @header 1 + 32 + 16
  @max Envelope.max_value_bytes()

  # The X25519 points of small order (RFC 7748 §6.1 and the non-canonical encodings
  # of the same points), each also with the ignored top bit set.
  @small_order [
    <<0::256>>,
    <<1, 0::248>>,
    Base.decode16!("E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800"),
    Base.decode16!("5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157"),
    <<0xEC, :binary.copy(<<0xFF>>, 30)::binary, 0x7F>>,
    <<0xED, :binary.copy(<<0xFF>>, 30)::binary, 0x7F>>,
    <<0xEE, :binary.copy(<<0xFF>>, 30)::binary, 0x7F>>
  ]

  setup do
    {public, secret} = :crypto.generate_key(:ecdh, :x25519)
    ref = :crypto.strong_rand_bytes(16)
    inv = :crypto.strong_rand_bytes(16)
    context = Envelope.context(ref, inv, __MODULE__, :issue)
    values = [:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(8)]
    {:ok, envelope} = Envelope.seal(public, values, context)

    {:ok,
     public: public,
     secret: secret,
     ref: ref,
     inv: inv,
     context: context,
     values: values,
     envelope: envelope}
  end

  describe "the control" do
    test "a sealed envelope opens with the recipient's key, values in declared order", c do
      assert Envelope.open(c.envelope, c.secret, c.public, 2, c.context) == {:ok, c.values}
    end

    test "no values, an empty value and a value of exactly 64 KiB round-trip", c do
      for values <- [[], [""], [:binary.copy(<<7>>, @max)]] do
        {:ok, envelope} = Envelope.seal(c.public, values, c.context)

        assert Envelope.open(envelope, c.secret, c.public, length(values), c.context) ==
                 {:ok, values}
      end
    end

    test "an envelope exactly at the declared bound opens", c do
      plaintext = <<@max::32, :binary.copy(<<1>>, @max)::binary>>
      {:ok, envelope} = Envelope.encrypt(c.public, plaintext, c.context)

      assert byte_size(envelope) - @header == Envelope.bound(1)
      assert {:ok, [_value]} = Envelope.open(envelope, c.secret, c.public, 1, c.context)
    end
  end

  describe "a low-order recipient key" do
    @describetag executing_only_envelope: :low_order

    test "every small-order point is refused before sealing", c do
      for point <- @small_order, key <- [point, top_bit(point)] do
        assert Envelope.seal(key, c.values, c.context) == {:error, :low_order}
      end
    end

    test "every small-order ephemeral key is refused before the agreement", c do
      <<version, _pk::binary-32, rest::binary>> = c.envelope

      for point <- @small_order, key <- [point, top_bit(point)] do
        assert Envelope.open(
                 <<version, key::binary, rest::binary>>,
                 c.secret,
                 c.public,
                 2,
                 c.context
               ) ==
                 {:error, :low_order}
      end
    end

    test "a recipient key of the wrong size is refused", c do
      for key <- [<<>>, <<9::248>>, <<9::264>>] do
        assert Envelope.seal(key, c.values, c.context) == {:error, :low_order}
      end
    end
  end

  describe "a flipped bit" do
    @describetag executing_only_envelope: :flip

    test "in the version byte", c do
      for bit <- 0..7 do
        assert Envelope.open(flip(c.envelope, 0, bit), c.secret, c.public, 2, c.context) ==
                 {:error, :version}
      end
    end

    test "in pk_E, the tag and the ciphertext", c do
      for byte <- 1..(byte_size(c.envelope) - 1), bit <- 0..7 do
        assert Envelope.open(flip(c.envelope, byte, bit), c.secret, c.public, 2, c.context) ==
                 {:error, :auth},
               "byte #{byte} bit #{bit}"
      end
    end

    test "in each additional-data field: ref, inv, resource and action", c do
      fields = [
        ref: Envelope.context(flip(c.ref, 0, 0), c.inv, __MODULE__, :issue),
        inv: Envelope.context(c.ref, flip(c.inv, 15, 7), __MODULE__, :issue),
        resource: Envelope.context(c.ref, c.inv, AshOnetime.Delivery.EnvelopeTesu, :issue),
        action: Envelope.context(c.ref, c.inv, __MODULE__, :issuf)
      ]

      for {field, context} <- fields do
        assert Envelope.open(c.envelope, c.secret, c.public, 2, context) == {:error, :auth},
               "#{field}"
      end

      for byte <- 0..(byte_size(c.context) - 1) do
        assert Envelope.open(c.envelope, c.secret, c.public, 2, flip(c.context, byte, 0)) ==
                 {:error, :auth},
               "context byte #{byte}"
      end
    end

    test "in the recipient key the opener binds", c do
      assert Envelope.open(c.envelope, c.secret, flip(c.public, 0, 1), 2, c.context) ==
               {:error, :auth}
    end
  end

  describe "the length" do
    @describetag executing_only_envelope: :length

    test "truncation at every length from 0 to the full envelope", c do
      full = byte_size(c.envelope)

      for length <- 0..(full - 1) do
        truncated = binary_part(c.envelope, 0, length)
        expected = if length < @header, do: :truncated, else: :auth

        assert Envelope.open(truncated, c.secret, c.public, 2, c.context) == {:error, expected},
               "length #{length}"
      end
    end

    test "a trailing byte after the envelope", c do
      assert Envelope.open(c.envelope <> <<0>>, c.secret, c.public, 2, c.context) ==
               {:error, :auth}
    end

    test "a trailing byte inside the authenticated plaintext", c do
      plaintext = encode(c.values) <> <<0>>
      {:ok, envelope} = Envelope.encrypt(c.public, plaintext, c.context)

      assert Envelope.open(envelope, c.secret, c.public, 2, c.context) == {:error, :trailing}
    end

    test "an entry count one over and one under the declared count", c do
      over = encode(c.values ++ ["extra"])
      under = encode(Enum.take(c.values, 1))

      {:ok, over_envelope} = Envelope.encrypt(c.public, over, c.context)
      {:ok, under_envelope} = Envelope.encrypt(c.public, under, c.context)

      assert Envelope.open(over_envelope, c.secret, c.public, 2, c.context) ==
               {:error, :trailing}

      assert Envelope.open(under_envelope, c.secret, c.public, 2, c.context) ==
               {:error, :count}

      assert Envelope.open(c.envelope, c.secret, c.public, 3, c.context) == {:error, :count}
      assert Envelope.open(c.envelope, c.secret, c.public, 1, c.context) == {:error, :trailing}
    end

    test "a size field that runs past the plaintext", c do
      [first, _second] = c.values
      plaintext = <<byte_size(first) + 1::32, first::binary>>
      {:ok, envelope} = Envelope.encrypt(c.public, plaintext, c.context)

      assert Envelope.open(envelope, c.secret, c.public, 1, c.context) == {:error, :count}
    end

    test "a size field over 64 KiB", c do
      for plaintext <- [<<@max + 1::32>>, <<@max + 1::32, :binary.copy(<<1>>, @max + 1)::binary>>] do
        {:ok, envelope} = Envelope.encrypt(c.public, plaintext, c.context)

        assert Envelope.open(envelope, c.secret, c.public, 2, c.context) == {:error, :size}
      end
    end

    test "a total over the declared bound is refused before decrypting", c do
      plaintext = <<@max::32, :binary.copy(<<1>>, @max)::binary, 0>>
      {:ok, envelope} = Envelope.encrypt(c.public, plaintext, c.context)

      assert byte_size(envelope) - @header == Envelope.bound(1) + 1
      assert Envelope.open(envelope, c.secret, c.public, 1, c.context) == {:error, :bound}
      assert Envelope.open(c.envelope, c.secret, c.public, 0, c.context) == {:error, :bound}
    end

    test "a value over 64 KiB is never sealed", c do
      assert Envelope.seal(c.public, [:binary.copy(<<1>>, @max + 1)], c.context) ==
               {:error, :size}

      assert Envelope.seal(c.public, [:not_binary], c.context) == {:error, :size}
    end
  end

  test "a key other than the recipient's opens nothing", c do
    {_public, other} = :crypto.generate_key(:ecdh, :x25519)
    assert Envelope.open(c.envelope, other, c.public, 2, c.context) == {:error, :auth}
  end

  test "a non-binary envelope is refused without an exception", c do
    for envelope <- [nil, ~c"abc", 1, {:sealed, c.envelope}] do
      assert Envelope.open(envelope, c.secret, c.public, 2, c.context) == {:error, :truncated}
    end
  end

  defp encode(values), do: Enum.map_join(values, &<<byte_size(&1)::32, &1::binary>>)

  defp top_bit(<<head::binary-size(31), last>>), do: <<head::binary, Bitwise.bor(last, 0x80)>>

  defp flip(binary, byte, bit) do
    <<head::binary-size(^byte), target, tail::binary>> = binary
    <<head::binary, Bitwise.bxor(target, Bitwise.bsl(1, bit)), tail::binary>>
  end
end
