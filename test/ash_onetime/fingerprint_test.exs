defmodule AshOnetime.FingerprintTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshOnetime.Canonical
  alias AshOnetime.Error
  alias AshOnetime.Fingerprint

  test "computes SHA-256 over the exact canonical bytes" do
    value = %{"amount" => 1_250, "currency" => "USD"}
    assert {:ok, canonical} = Canonical.encode(value)
    assert {:ok, digest} = Fingerprint.compute(value)
    assert digest == :crypto.hash(:sha256, canonical)
    assert byte_size(digest) == 32
  end

  test "compute/2 enforces the configured max_fingerprint_bytes on the canonical input" do
    value = %{"pad" => String.duplicate("x", 1_000)}
    assert {:ok, encoded} = Canonical.encode(value)

    assert {:ok, _digest} = Fingerprint.compute(value, byte_size(encoded))

    assert {:error, %Error{code: :fingerprint_too_large}} =
             Fingerprint.compute(value, byte_size(encoded) - 1)
  end

  property "map fingerprints use independently sorted encoded keys" do
    check all(left <- integer(), right <- integer()) do
      value = %{"bb" => left, "a" => right}
      expected = :crypto.hash(:sha256, independently_encoded_map!(value))

      assert {:ok, ^expected} = Fingerprint.compute(value)
    end
  end

  property "canonical type distinctions survive hashing" do
    check all(integer <- integer(-1_000_000..1_000_000)) do
      refute Fingerprint.compute(integer) == Fingerprint.compute(Integer.to_string(integer))
    end
  end

  test "canonicalization failures return typed errors" do
    assert {:error, %Error{code: :unsupported_term}} =
             Fingerprint.compute(%{"nested" => [%URI{scheme: "https"}]})
  end

  defp independently_encoded_map!(value) do
    entries =
      value
      |> Enum.map(fn {key, item} ->
        {:ok, encoded_key} = Canonical.encode(key)
        {:ok, encoded_item} = Canonical.encode(item)
        {encoded_key, encoded_item}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    payload =
      IO.iodata_to_binary([
        <<map_size(value)::unsigned-big-32>>,
        Enum.map(entries, fn {key, item} -> [key, item] end)
      ])

    <<0x06, byte_size(payload)::unsigned-big-32, payload::binary>>
  end
end
