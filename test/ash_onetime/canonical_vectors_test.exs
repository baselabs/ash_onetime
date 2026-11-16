defmodule AshOnetime.CanonicalVectorsTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Canonical
  alias AshOnetime.Canonical.Decoder
  alias AshOnetime.Error
  alias AshOnetime.Fingerprint

  @path Path.expand("../../priv/vectors/canonical-1.json", __DIR__)
  @external_resource @path
  @raw File.read!(@path)
  @vectors Jason.decode!(@raw)

  # Format 1 vectors never change. A new vector or a new format is a new file.
  @pinned_sha256 "3e6b332d05b393a8ccc807cd773319c2fd1ea71529126b86d4462ae1c61d6ad9"

  @decode_errors %{
    "trailing_bytes" => :invalid_encoding,
    "map_key_order" => :noncanonical_encoding,
    "duplicate_map_key" => :duplicate_map_key,
    "unknown_tag" => :invalid_encoding,
    "truncated_frame" => :invalid_encoding,
    "noncanonical_integer" => :invalid_encoding,
    "invalid_payload" => :invalid_encoding
  }

  test "the format 1 vector file is immutable" do
    assert Base.encode16(:crypto.hash(:sha256, @raw), case: :lower) == @pinned_sha256
  end

  test "the vector file names format 1 and the bounds the encoder enforces" do
    assert %{"version" => 1, "bounds" => bounds} = @vectors
    assert Canonical.format() == 1

    assert Canonical.bounds() == %{
             integer_magnitude: String.to_integer(bounds["integer_magnitude"]),
             binary_bytes: bounds["binary_bytes"],
             container_items: bounds["container_items"],
             total_values: bounds["total_values"],
             depth: bounds["depth"],
             encoded_bytes: bounds["encoded_bytes"]
           }
  end

  @tag :canonical_vector_bytes_mutation
  test "every accepted vector encodes, fingerprints and decodes to its published bytes" do
    for %{"name" => name, "value" => notation, "canonical" => hex, "sha256" => sha} <-
          @vectors["accept"] do
      value = value!(notation)
      expected = Base.decode16!(hex, case: :lower)
      digest = Base.decode16!(sha, case: :lower)

      assert {name, {:ok, expected}} == {name, Canonical.encode(value)}
      assert {name, {:ok, digest}} == {name, Fingerprint.compute(value)}
      assert {name, {:ok, value}} == {name, Decoder.decode(expected)}
    end
  end

  @tag :canonical_vector_bounds_mutation
  test "every rejected vector fails with its published error" do
    for %{"name" => name, "value" => notation, "error" => code} = vector <- @vectors["reject"] do
      published = published_rejection(code, vector)
      result = Canonical.encode(value!(notation))

      assert {name, published} == {name, rejection(result)}
    end
  end

  test "every invalid encoding is refused by the decoder" do
    for %{"name" => name, "rule" => rule, "canonical" => hex} <- @vectors["invalid_encoding"] do
      assert {:error, %Error{code: code}} = Decoder.decode(Base.decode16!(hex, case: :lower))
      assert {name, code} == {name, Map.fetch!(@decode_errors, rule)}
    end
  end

  test "the package ships the vector file" do
    assert "priv/vectors" in Mix.Project.config()[:package][:files]
  end

  defp rejection({:error, %Error{code: code, details: details}}), do: {code, details}
  defp rejection(other), do: other

  defp published_rejection("unsupported_term", _vector), do: {:unsupported_term, %{}}

  defp published_rejection("limit_exceeded", %{"limit" => limit, "maximum" => maximum}) do
    {:limit_exceeded,
     %{limit: String.to_existing_atom(limit), maximum: String.to_integer(maximum)}}
  end

  defp value!(%{"t" => "nil"}), do: nil
  defp value!(%{"t" => "bool", "v" => value}) when is_boolean(value), do: value
  defp value!(%{"t" => "int", "v" => value}), do: String.to_integer(value)

  defp value!(%{"t" => "bin", "repeat" => hex, "count" => count}),
    do: :binary.copy(Base.decode16!(hex, case: :lower), count)

  defp value!(%{"t" => "bin", "hex" => hex}), do: Base.decode16!(hex, case: :lower)
  defp value!(%{"t" => "atom", "v" => name}), do: String.to_existing_atom(name)

  defp value!(%{"t" => "list", "repeat" => item, "count" => count}),
    do: List.duplicate(value!(item), count)

  defp value!(%{"t" => "list", "v" => items}), do: Enum.map(items, &value!/1)

  defp value!(%{"t" => "nest", "depth" => depth}),
    do: Enum.reduce(1..depth//1, [], fn _level, inner -> [inner] end)

  defp value!(%{"t" => "map", "v" => entries}),
    do: Map.new(entries, fn [key, value] -> {value!(key), value!(value)} end)

  defp value!(%{"t" => "float", "v" => value}), do: value / 1

  defp value!(%{"t" => "tuple", "v" => items}),
    do: items |> Enum.map(&value!/1) |> List.to_tuple()
end
