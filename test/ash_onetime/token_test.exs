defmodule AshOnetime.TokenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshOnetime.Canonical
  alias AshOnetime.Canonical.Decoder
  alias AshOnetime.Error
  alias AshOnetime.Test.Clock
  alias AshOnetime.Test.KeyResolver
  alias AshOnetime.Token

  @issued_at ~U[2026-08-04 12:00:00.000000Z]
  @expires_at ~U[2026-08-04 12:01:00.000000Z]
  @namespace "payments"
  @hmac_key :binary.copy(<<0xA5>>, 32)
  @private_key Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public_key Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")

  setup do
    Clock.freeze(@issued_at)
    on_exit(&Clock.reset/0)
  end

  test "mints, signs, and verifies an exact canonical base64url envelope" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    assert String.starts_with?(encoded, "ash_onetime.")
    assert byte_size(encoded) <= 8_192
    assert {:ok, ^token} = Token.verify(encoded, KeyResolver, verify_options())

    raw = decode_wire!(encoded)
    assert "ash_onetime." <> Base.url_encode64(raw, padding: false) == encoded
    assert {:ok, %{"body" => body, "signature" => signature}} = Decoder.decode(raw)

    assert Map.keys(body) |> Enum.sort() ==
             ["algorithm", "expires_at", "issued_at", "key", "key_id", "namespace"]

    assert body["algorithm"] == "hmac-sha256"
    assert body["key_id"] == "hmac-main"
    assert body["namespace"] == @namespace
    assert is_binary(signature) and byte_size(signature) == 32
  end

  @tag :signature_mutation
  test "signature binds the exact canonical body bytes" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    assert {:ok, ^token} = Token.verify(encoded, KeyResolver, verify_options())
  end

  property "mint -> sign -> verify round-trips for both algorithms over generated fields" do
    check all(
            {algorithm, key_id} <-
              member_of([{:hmac_sha256, "hmac-main"}, {:ed25519, "ed-current"}]),
            namespace <- string(:alphanumeric, min_length: 1, max_length: 64),
            key <- binary(min_length: 1, max_length: 200),
            issued_offset <- integer(-3600..3600),
            expiry_offset <- one_of([constant(nil), integer(0..3600)])
          ) do
      issued_at = DateTime.add(@issued_at, issued_offset, :second)
      expires_at = expiry_offset && DateTime.add(issued_at, expiry_offset, :second)

      assert {:ok, token} =
               Token.mint(key,
                 algorithm: algorithm,
                 key_id: key_id,
                 namespace: namespace,
                 issued_at: issued_at,
                 expires_at: expires_at
               )

      # freeze evaluation to issuance so the acceptance window always admits the fresh token
      Clock.freeze(issued_at)

      assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())

      assert {:ok, ^token} =
               Token.verify(
                 encoded,
                 KeyResolver,
                 verify_options(algorithm: algorithm, namespace: namespace)
               )
    end
  end

  property "any single-byte tamper of a valid signed token fails closed" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    raw = decode_wire!(encoded)

    check all(
            index <- integer(0..(byte_size(raw) - 1)),
            xor <- integer(1..255)
          ) do
      # Flipping ANY byte of the signed wire — body, signature tail, or a structural byte — must
      # reject: reaching the signature tail forces the full-length constant-time comparison, and a
      # body/structural change breaks canonical byte-identity. Never {:ok}.
      tampered = mutate_byte(raw, index, xor)

      assert {:error, %Error{}} =
               Token.verify(wire(tampered), KeyResolver, verify_options())
    end
  end

  test "verification requires and binds the expected algorithm and namespace" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())

    assert {:error, %Error{code: :missing_option, details: %{option: :algorithm}}} =
             Token.verify(encoded, KeyResolver, Keyword.delete(verify_options(), :algorithm))

    assert {:error, %Error{code: :algorithm_mismatch}} =
             Token.verify(
               encoded,
               KeyResolver,
               Keyword.put(verify_options(), :algorithm, :ed25519)
             )

    assert {:error, %Error{code: :missing_option, details: %{option: :namespace}}} =
             Token.verify(encoded, KeyResolver, Keyword.delete(verify_options(), :namespace))

    assert {:error, %Error{code: :namespace_mismatch}} =
             Token.verify(
               encoded,
               KeyResolver,
               Keyword.put(verify_options(), :namespace, "other")
             )
  end

  test "issuance and expiry are checked at exact verification boundaries" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())

    oldest_evaluation = DateTime.add(@issued_at, 65, :second)
    Clock.freeze(oldest_evaluation)

    assert {:ok, ^token} =
             Token.verify(encoded, KeyResolver, verify_options())

    Clock.freeze(DateTime.add(oldest_evaluation, 1, :microsecond))

    assert {:error, %Error{code: :invalid_window}} =
             Token.verify(encoded, KeyResolver, verify_options())

    expiry_edge = DateTime.add(@expires_at, 5, :second)
    Clock.freeze(expiry_edge)

    assert {:ok, ^token} =
             Token.verify(encoded, KeyResolver, verify_options(max_age: 120))

    Clock.freeze(DateTime.add(expiry_edge, 1, :microsecond))

    assert {:error, %Error{code: :invalid_window}} =
             Token.verify(encoded, KeyResolver, verify_options(max_age: 120))
  end

  test "meaningful signature and signed-body byte tampering fail closed" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    assert {:ok, envelope} = Decoder.decode(decode_wire!(encoded))

    tampered_signature = flip_first_byte(envelope["signature"])
    refute tampered_signature == envelope["signature"]

    assert {:ok, signature_wire} =
             Canonical.encode(%{envelope | "signature" => tampered_signature})

    assert {:error, %Error{code: :invalid_signature}} =
             Token.verify(wire(signature_wire), KeyResolver, verify_options())

    tampered_body = put_in(envelope, ["body", "key"], "different-key")
    assert {:ok, body_wire} = Canonical.encode(tampered_body)

    assert {:error, %Error{code: :invalid_signature}} =
             Token.verify(wire(body_wire), KeyResolver, verify_options())
  end

  test "wrong algorithm, key ID, and verification key fail closed" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    assert {:ok, envelope} = Decoder.decode(decode_wire!(encoded))

    substituted = put_in(envelope, ["body", "algorithm"], "ed25519")
    assert {:ok, substituted_wire} = Canonical.encode(substituted)

    substitution_context =
      put_in(
        resolver_context(),
        [:keys, {:verify, "hmac-main", :ed25519}],
        public(@public_key)
      )

    assert {:error, %Error{code: :invalid_signature}} =
             Token.verify(
               wire(substituted_wire),
               KeyResolver,
               verify_options(
                 algorithm: :ed25519,
                 resolver_context: substitution_context
               )
             )

    wrong_id = put_in(envelope, ["body", "key_id"], "missing")
    assert {:ok, wrong_id_wire} = Canonical.encode(wrong_id)

    assert {:error, %Error{code: :key_not_found}} =
             Token.verify(wire(wrong_id_wire), KeyResolver, verify_options())

    wrong_context =
      put_in(
        resolver_context(),
        [:keys, {:verify, "hmac-main", :hmac_sha256}],
        same_service(:binary.copy(<<0x11>>, 32))
      )

    assert {:error, %Error{code: :invalid_signature}} =
             Token.verify(
               encoded,
               KeyResolver,
               Keyword.put(verify_options(), :resolver_context, wrong_context)
             )
  end

  test "noncanonical base64url, map order, duplicate fields, and inexact fields reject" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    raw = decode_wire!(encoded)
    assert {:ok, envelope} = Decoder.decode(raw)
    assert {:ok, encoded_body} = Canonical.encode(envelope["body"])
    assert {:ok, encoded_signature} = Canonical.encode(envelope["signature"])
    assert {:ok, body_key} = Canonical.encode("body")
    assert {:ok, signature_key} = Canonical.encode("signature")

    padded_candidate = "ash_onetime." <> Base.url_encode64(raw, padding: true)
    padded = if padded_candidate == encoded, do: encoded <> "=", else: padded_candidate

    assert {:error, %Error{code: code}} = Token.verify(padded, KeyResolver, verify_options())
    assert code in [:invalid_token, :noncanonical_envelope]

    noncanonical = raw_map([{signature_key, encoded_signature}, {body_key, encoded_body}])

    assert {:error, %Error{code: :noncanonical_envelope}} =
             Token.verify(wire(noncanonical), KeyResolver, verify_options())

    duplicate =
      raw_map([
        {body_key, encoded_body},
        {signature_key, encoded_signature},
        {signature_key, encoded_signature}
      ])

    assert {:error, %Error{code: :duplicate_field}} =
             Token.verify(wire(duplicate), KeyResolver, verify_options())

    assert {:ok, extra_field} = Canonical.encode(Map.put(envelope, "extra", nil))

    assert {:error, %Error{code: :malformed_token}} =
             Token.verify(wire(extra_field), KeyResolver, verify_options())
  end

  test "HMAC resolver material must itself prove same-service trust" do
    assert {:ok, token} = mint_hmac()

    for material <- [@hmac_key, %{key: @hmac_key}, %{key: @hmac_key, trust: :external}] do
      sign_context =
        put_in(resolver_context(), [:keys, {:sign, "hmac-main", :hmac_sha256}], material)

      assert {:error, %Error{code: :invalid_trust_boundary}} =
               Token.sign(token, KeyResolver, sign_context)
    end

    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())

    for material <- [@hmac_key, %{key: @hmac_key}, %{key: @hmac_key, trust: :external}] do
      verify_context =
        put_in(resolver_context(), [:keys, {:verify, "hmac-main", :hmac_sha256}], material)

      assert {:error, %Error{code: :invalid_trust_boundary}} =
               Token.verify(
                 encoded,
                 KeyResolver,
                 Keyword.put(verify_options(), :resolver_context, verify_context)
               )
    end
  end

  test "Ed25519 signing and verification resolution are purpose-separated and public-only" do
    assert {:ok, token} =
             Token.mint("nonce-ed25519",
               algorithm: :ed25519,
               key_id: "ed-current",
               namespace: "redemption",
               issued_at: @issued_at,
               expires_at: @expires_at
             )

    signing_context = %{
      keys: %{{:sign, "ed-current", :ed25519} => private(@private_key)}
    }

    verification_context = %{
      keys: %{{:verify, "ed-current", :ed25519} => public(@public_key)}
    }

    assert {:ok, encoded} = Token.sign(token, KeyResolver, signing_context)

    assert {:ok, ^token} =
             Token.verify(
               encoded,
               KeyResolver,
               verify_options(
                 algorithm: :ed25519,
                 namespace: "redemption",
                 resolver_context: verification_context
               )
             )

    refute Map.has_key?(verification_context.keys, {:sign, "ed-current", :ed25519})
    refute verification_context.keys[{:verify, "ed-current", :ed25519}] == private(@private_key)
  end

  test "sign validates hand-built structs with the same field rules as mint" do
    valid = %Token{
      algorithm: :hmac_sha256,
      key_id: "hmac-main",
      namespace: @namespace,
      key: "single-use-key",
      issued_at: @issued_at,
      expires_at: @expires_at
    }

    invalid = [
      {%{valid | algorithm: :unknown}, :unsupported_algorithm},
      {%{valid | key_id: ""}, :invalid_key_id},
      {%{valid | namespace: ""}, :invalid_namespace},
      {%{valid | key: ""}, :invalid_key},
      {%{valid | issued_at: :not_a_datetime}, :invalid_issued_at},
      {%{valid | expires_at: DateTime.add(@issued_at, -1, :microsecond)}, :invalid_expires_at}
    ]

    for {token, code} <- invalid do
      assert {:error, %Error{code: ^code}} = Token.sign(token, KeyResolver, resolver_context())
    end
  end

  test "mint and raw token byte bounds fail closed" do
    assert {:error, %Error{code: :invalid_key}} =
             Token.mint("",
               algorithm: :hmac_sha256,
               key_id: "hmac-main",
               namespace: @namespace,
               issued_at: @issued_at
             )

    assert {:error, %Error{code: :key_too_large}} =
             Token.mint(:binary.copy(<<0>>, 1_025),
               algorithm: :hmac_sha256,
               key_id: "hmac-main",
               namespace: @namespace,
               issued_at: @issued_at
             )

    assert {:error, %Error{code: :token_too_large}} =
             Token.verify(:binary.copy(<<0>>, 8_193), KeyResolver, verify_options())
  end

  @tag :token_identifier_bound_mutation
  test "token identifier limits accept exact edges and reject first excess" do
    exact = :binary.copy(<<0x49>>, 128)
    excess = exact <> <<0x49>>

    assert {:ok, %Token{key_id: ^exact, namespace: ^exact}} =
             Token.mint("nonce",
               algorithm: :hmac_sha256,
               key_id: exact,
               namespace: exact,
               issued_at: @issued_at
             )

    assert {:error, %Error{code: :invalid_key_id}} =
             Token.mint("nonce",
               algorithm: :hmac_sha256,
               key_id: excess,
               namespace: exact,
               issued_at: @issued_at
             )

    assert {:error, %Error{code: :invalid_namespace}} =
             Token.mint("nonce",
               algorithm: :hmac_sha256,
               key_id: exact,
               namespace: excess,
               issued_at: @issued_at
             )
  end

  @tag :token_from_body_bounds_mutation
  test "verify re-validates the decoded body's key_id bound before the signature" do
    # mint refuses to build an over-length key_id, so forge the wire envelope directly. verify's
    # token_from_body re-validates the decoded body's identifier/key bounds BEFORE it resolves a
    # key or checks the signature, so the over-length field — not a signature mismatch — is the
    # reject. A garbage signature proves the bound fires first.
    encoded = forge_token(%{"key_id" => :binary.copy("A", 129)})

    assert {:error, %Error{code: :invalid_key_id}} =
             Token.verify(encoded, KeyResolver, verify_options())
  end

  test "verify re-validates the decoded body's key bound before the signature" do
    encoded = forge_token(%{"key" => :binary.copy(<<0>>, 1_025)})

    assert {:error, %Error{code: :key_too_large}} =
             Token.verify(encoded, KeyResolver, verify_options())
  end

  test "malformed DateTime structs fail closed across mint, sign, and verify" do
    malformed = %{@issued_at | month: 13}

    assert {:error, %Error{code: :invalid_issued_at}} =
             Token.mint("nonce",
               algorithm: :hmac_sha256,
               key_id: "hmac-main",
               namespace: @namespace,
               issued_at: malformed
             )

    assert {:ok, token} = mint_hmac()

    assert {:error, %Error{code: :invalid_issued_at}} =
             Token.sign(%{token | issued_at: malformed}, KeyResolver, resolver_context())

    assert {:error, %Error{code: :invalid_expires_at}} =
             Token.sign(%{token | expires_at: malformed}, KeyResolver, resolver_context())

    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    Clock.freeze(malformed)

    assert {:error, %Error{code: :invalid_evaluated_at}} =
             Token.verify(encoded, KeyResolver, verify_options())
  end

  test "verification duration magnitudes fail closed before DateTime arithmetic" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())
    excess = 2_147_483_648

    assert {:error, %Error{code: :invalid_window}} =
             Token.verify(encoded, KeyResolver, verify_options(max_age: excess, skew: 0))

    assert {:error, %Error{code: :invalid_window}} =
             Token.verify(encoded, KeyResolver, verify_options(max_age: 0, skew: excess))
  end

  test "verification rejects a caller-supplied evaluation instant" do
    assert {:ok, token} = mint_hmac()
    assert {:ok, encoded} = Token.sign(token, KeyResolver, resolver_context())

    assert {:error, %Error{code: :invalid_options}} =
             Token.verify(
               encoded,
               KeyResolver,
               verify_options(evaluated_at: @issued_at)
             )
  end

  @tag timeout: 180_000
  test "verification clock override fails closed outside the test build" do
    script = ~S'''
    defmodule ReviewClock do
      def now, do: ~U[2000-01-01 00:00:00.000000Z]
    end

    defmodule ReviewResolver do
      def resolve(_purpose, "review-key", :hmac_sha256, key),
        do: {:ok, %{key: key, trust: :same_service}}
    end

    issued_at = ~U[2000-01-01 00:00:00.000000Z]
    secret = :binary.copy(<<0x42>>, 32)

    {:ok, token} =
      AshOnetime.Token.mint("nonce",
        algorithm: :hmac_sha256,
        key_id: "review-key",
        namespace: "review",
        issued_at: issued_at,
        expires_at: DateTime.add(issued_at, 60, :second)
      )

    {:ok, encoded} = AshOnetime.Token.sign(token, ReviewResolver, secret)

    result =
      AshOnetime.Token.verify(encoded, ReviewResolver,
        algorithm: :hmac_sha256,
        namespace: "review",
        max_age: 60,
        clock: ReviewClock,
        resolver_context: secret
      )

    IO.inspect(result, limit: :infinity)
    '''

    # The dev subprocess inherits a clean env: config/config.exs imports test.exs ONLY for
    # the test env, so in MIX_ENV=dev the allow_clock_override config is unset and
    # Application.compile_env(:ash_onetime, :allow_clock_override, false) freezes to false
    # at the dev build's compile time. The :clock override must fail closed there.
    build_path =
      Path.join([
        File.cwd!(),
        "_build",
        "ash-onetime-dev-build-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      ])

    on_exit(fn -> File.rm_rf!(build_path) end)
    link_dependency_builds!(Mix.Project.build_path(), build_path)

    {output, status} =
      try do
        System.cmd("mix", ["run", "--no-start", "--no-deps-check", "-e", script],
          env: [{"MIX_BUILD_PATH", build_path}, {"MIX_ENV", "dev"}],
          stderr_to_stdout: true
        )
      after
        File.rm_rf!(build_path)
      end

    refute File.exists?(build_path)
    assert status == 0
    assert output =~ "code: :invalid_options"
    assert output =~ "verification clock override requires explicit"
    refute output =~ "{:ok,"
  end

  test "out-of-range decoded expiry keeps its expiry error code" do
    body = %{
      "algorithm" => "hmac-sha256",
      "expires_at" => Integer.pow(2, 255) - 1,
      "issued_at" => DateTime.to_unix(@issued_at, :microsecond),
      "key" => "nonce",
      "key_id" => "hmac-main",
      "namespace" => @namespace
    }

    assert {:ok, envelope} = Canonical.encode(%{"body" => body, "signature" => @hmac_key})

    assert {:error, %Error{code: :invalid_expires_at}} =
             Token.verify(wire(envelope), KeyResolver, verify_options())
  end

  test "mint uses the configured trusted clock" do
    assert {:ok, token} =
             Token.mint("clocked",
               algorithm: :hmac_sha256,
               key_id: "hmac-main",
               namespace: @namespace,
               clock: Clock
             )

    assert token.issued_at == @issued_at
  end

  defp mint_hmac do
    Token.mint("nonce-123",
      algorithm: :hmac_sha256,
      key_id: "hmac-main",
      namespace: @namespace,
      issued_at: @issued_at,
      expires_at: @expires_at
    )
  end

  defp verify_options(overrides \\ []) do
    Keyword.merge(
      [
        algorithm: :hmac_sha256,
        namespace: @namespace,
        max_age: 60,
        skew: 5,
        clock: Clock,
        resolver_context: resolver_context()
      ],
      overrides
    )
  end

  defp resolver_context do
    %{
      keys: %{
        {:sign, "hmac-main", :hmac_sha256} => same_service(@hmac_key),
        {:verify, "hmac-main", :hmac_sha256} => same_service(@hmac_key),
        {:sign, "ed-current", :ed25519} => private(@private_key),
        {:verify, "ed-current", :ed25519} => public(@public_key)
      }
    }
  end

  defp same_service(key), do: %{key: key, trust: :same_service}
  defp private(key), do: %{key: key, kind: :private}
  defp public(key), do: %{key: key, kind: :public}

  defp link_dependency_builds!(source_build_path, target_build_path) do
    target_lib_path = Path.join(target_build_path, "lib")
    File.mkdir_p!(target_lib_path)

    source_build_path
    |> Path.join("lib/*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "ash_onetime"))
    |> Enum.each(fn dependency_path ->
      File.ln_s!(dependency_path, Path.join(target_lib_path, Path.basename(dependency_path)))
    end)
  end

  defp decode_wire!("ash_onetime." <> encoded), do: Base.url_decode64!(encoded, padding: false)

  defp mutate_byte(binary, index, xor) do
    <<prefix::binary-size(^index), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, xor)::8, suffix::binary>>
  end

  # Forges a wire token from an arbitrary body (bypassing mint's own bounds), used to drive the
  # decode-side re-validation in Token.verify. The signature is deliberately garbage — the body
  # bounds are enforced before it is ever consulted.
  defp forge_token(overrides) do
    body =
      Map.merge(
        %{
          "algorithm" => "hmac-sha256",
          "key_id" => "hmac-main",
          "namespace" => @namespace,
          "key" => "nonce-123",
          "issued_at" => DateTime.to_unix(@issued_at, :microsecond),
          "expires_at" => nil
        },
        overrides
      )

    {:ok, raw} = Canonical.encode(%{"body" => body, "signature" => :binary.copy(<<0>>, 32)})
    "ash_onetime." <> Base.url_encode64(raw, padding: false)
  end

  defp wire(envelope), do: "ash_onetime." <> Base.url_encode64(envelope, padding: false)

  defp flip_first_byte(<<first, rest::binary>>),
    do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp raw_map(entries) do
    encoded_entries = Enum.map(entries, fn {key, value} -> [key, value] end)
    payload = <<length(entries)::unsigned-big-32>> <> IO.iodata_to_binary(encoded_entries)
    <<0x06, byte_size(payload)::unsigned-big-32, payload::binary>>
  end
end
