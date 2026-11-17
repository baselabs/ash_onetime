defmodule AshOnetime.Delivery.Envelope do
  @moduledoc false

  # Seals executing-only values to the one-time X25519 public key of a single
  # `AshOnetime.deliver/2` call.
  #
  #   * X25519 ephemeral agreement; a small-order point (whose shared secret is all zero,
  #     RFC 7748 §6.1) is refused before the agreement, and an all-zero secret after it;
  #   * HKDF-SHA-256 (RFC 5869) with salt pk_E <> pk_R and info
  #     "ash_onetime delivery v1" <> context, giving a 32-byte key and a 12-byte nonce;
  #   * AES-256-GCM with a 16-byte tag over the additional data <<version>> <> context;
  #   * plaintext: each value, in declared order, as <<size::32, value::binary>>;
  #   * envelope: <<version, pk_E::binary-32, tag::binary-16, ciphertext::binary>>.
  #
  # Decoding is bounded by the declared value count; nothing is ever passed to
  # `binary_to_term`. Each refusal has its own internal reason so every check is
  # observable on its own; callers outside this module see only `:executing_only_lost`.

  @version 1
  @info "ash_onetime delivery v1"
  @max_value_bytes 65_536
  @key_bytes 32
  @tag_bytes 16
  @nonce_bytes 12
  @header_bytes 1 + @key_bytes + @tag_bytes

  # The X25519 points of small order (libsodium's blacklist), compared with the top bit
  # of the last byte cleared, as X25519 ignores it (RFC 7748 §5).
  @small_order [
    <<0::256>>,
    <<1, 0::248>>,
    Base.decode16!("E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800"),
    Base.decode16!("5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157"),
    <<0xEC, :binary.copy(<<0xFF>>, 30)::binary, 0x7F>>,
    <<0xED, :binary.copy(<<0xFF>>, 30)::binary, 0x7F>>,
    <<0xEE, :binary.copy(<<0xFF>>, 30)::binary, 0x7F>>
  ]

  @type reason ::
          :low_order
          | :agreement
          | :version
          | :truncated
          | :bound
          | :auth
          | :count
          | :size
          | :trailing

  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @spec bound(non_neg_integer()) :: non_neg_integer()
  def bound(count) when is_integer(count) and count >= 0, do: count * (4 + @max_value_bytes)

  @spec context(binary(), binary(), module(), atom()) :: binary()
  def context(ref, inv, resource, action)
      when is_binary(ref) and is_binary(inv) and is_atom(resource) and is_atom(action) do
    Enum.map_join(
      [ref, inv, Atom.to_string(resource), Atom.to_string(action)],
      &<<byte_size(&1)::16, &1::binary>>
    )
  end

  @spec seal(binary(), [binary()], binary()) :: {:ok, binary()} | {:error, reason()}
  def seal(recipient, values, context) when is_list(values) and is_binary(context) do
    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= @max_value_bytes)) do
      encrypt(recipient, Enum.map_join(values, &<<byte_size(&1)::32, &1::binary>>), context)
    else
      {:error, :size}
    end
  end

  @doc false
  @spec encrypt(binary(), binary(), binary()) :: {:ok, binary()} | {:error, reason()}
  def encrypt(recipient, plaintext, context) when is_binary(plaintext) and is_binary(context) do
    with :ok <- public_key(recipient) do
      {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519)

      with {:ok, shared} <- agree(recipient, ephemeral_secret) do
        {key, nonce} = derive(shared, ephemeral_public, recipient, context)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(
            :aes_256_gcm,
            key,
            nonce,
            plaintext,
            additional_data(context),
            @tag_bytes,
            true
          )

        {:ok, <<@version, ephemeral_public::binary, tag::binary, ciphertext::binary>>}
      end
    end
  end

  @spec open(binary(), binary(), binary(), non_neg_integer(), binary()) ::
          {:ok, [binary()]} | {:error, reason()}
  def open(envelope, secret, recipient, count, context)
      when is_binary(envelope) and is_binary(secret) and is_binary(recipient) and
             is_integer(count) and count >= 0 and is_binary(context) do
    with {:ok, ephemeral_public, tag, ciphertext} <- split(envelope, bound(count)),
         :ok <- public_key(ephemeral_public),
         {:ok, shared} <- agree(ephemeral_public, secret),
         {key, nonce} = derive(shared, ephemeral_public, recipient, context),
         {:ok, plaintext} <- decrypt(key, nonce, ciphertext, tag, context) do
      decode(plaintext, count, [])
    end
  end

  def open(_envelope, _secret, _recipient, _count, _context), do: {:error, :truncated}

  defp split(<<version, _rest::binary>>, _bound) when version != @version,
    do: {:error, :version}

  defp split(envelope, _bound) when byte_size(envelope) < @header_bytes,
    do: {:error, :truncated}

  defp split(envelope, bound) when byte_size(envelope) - @header_bytes > bound,
    do: {:error, :bound}

  defp split(
         <<@version, ephemeral_public::binary-size(@key_bytes), tag::binary-size(@tag_bytes),
           ciphertext::binary>>,
         _bound
       ),
       do: {:ok, ephemeral_public, tag, ciphertext}

  defp public_key(<<head::binary-size(31), last>>) do
    if <<head::binary, Bitwise.band(last, 0x7F)>> in @small_order,
      do: {:error, :low_order},
      else: :ok
  end

  defp public_key(_key), do: {:error, :low_order}

  defp agree(public, secret) do
    case :crypto.compute_key(:ecdh, public, secret, :x25519) do
      <<0::256>> -> {:error, :low_order}
      <<_::binary-size(@key_bytes)>> = shared -> {:ok, shared}
      _other -> {:error, :agreement}
    end
  rescue
    _exception -> {:error, :agreement}
  catch
    _kind, _reason -> {:error, :agreement}
  end

  defp derive(shared, ephemeral_public, recipient, context) do
    prk = hmac(ephemeral_public <> recipient, shared)
    info = @info <> context
    first = hmac(prk, info <> <<1>>)
    second = hmac(prk, first <> info <> <<2>>)

    <<key::binary-size(@key_bytes), nonce::binary-size(@nonce_bytes), _::binary>> =
      first <> second

    {key, nonce}
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp decrypt(key, nonce, ciphertext, tag, context) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           additional_data(context),
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _error -> {:error, :auth}
    end
  rescue
    _exception -> {:error, :auth}
  catch
    _kind, _reason -> {:error, :auth}
  end

  defp additional_data(context), do: <<@version, context::binary>>

  defp decode(<<>>, 0, values), do: {:ok, Enum.reverse(values)}
  defp decode(_rest, 0, _values), do: {:error, :trailing}

  defp decode(<<size::32, _rest::binary>>, _count, _values) when size > @max_value_bytes,
    do: {:error, :size}

  defp decode(<<size::32, value::binary-size(size), rest::binary>>, count, values),
    do: decode(rest, count - 1, [value | values])

  defp decode(_rest, _count, _values), do: {:error, :count}
end
