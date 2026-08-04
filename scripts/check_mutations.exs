defmodule AshOnetime.MutationCheck do
  @moduledoc false

  @database_url "ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test"

  @mutations %{
    "canonical" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  @integer_tag 0x02",
      mutated: "  @integer_tag 0x03",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_mutation",
      test_name: "integer encoding uses its distinct pinned domain tag",
      assertion: "assert {:ok, <<2, 0, 0, 0, 1, \"1\">>} = Canonical.encode(1)"
    },
    "canonical-order" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "      ordered = Enum.sort_by(entries, &elem(&1, 0))",
      mutated: "      ordered = entries",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_order_mutation",
      test_name: "map encoding follows independently sorted encoded keys",
      assertion: "assert {:ok, ^expected} = Canonical.encode(value)"
    },
    "canonical-surface" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  defp unsupported_error,",
      mutated:
        "  def decode(encoded), do: AshOnetime.Canonical.Decoder.decode(encoded)\n\n  defp unsupported_error,",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_surface_mutation",
      test_name: "canonical public surface does not export decoding",
      assertion: "refute function_exported?(Canonical, :decode, 1)"
    },
    "canonical-decoder-docs" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  @moduledoc false",
      mutated: "  @moduledoc \"Internal canonical decoder\"",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_decoder_docs_mutation",
      test_name: "canonical decoder module stays hidden from public documentation",
      assertion: "assert :hidden = decoder_moduledoc()"
    },
    "window" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(issued_at, oldest) in [:eq, :gt]",
      mutated: "DateTime.compare(issued_at, oldest) == :gt",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_mutation",
      test_name: "oldest replay-window endpoint is inclusive",
      assertion: "assert :ok = Window.validate(oldest, nil, @evaluated_at, 60, 5)"
    },
    "token-identifier-bound" => %{
      path: "lib/ash_onetime/token.ex",
      original: "  @max_identifier_bytes 128",
      mutated: "  @max_identifier_bytes 10_000",
      test: "test/ash_onetime/token_test.exs",
      tag: "token_identifier_bound_mutation",
      test_name: "token identifier limits accept exact edges and reject first excess",
      assertion: "assert {:error, %Error{code: :invalid_key_id}} ="
    },
    "hmac-key-bound" => %{
      path: "lib/ash_onetime/signer/hmac.ex",
      original: "  @max_key_bytes 4_096",
      mutated: "  @max_key_bytes 10_000",
      test: "test/ash_onetime/signer/hmac_test.exs",
      tag: "hmac_key_bound_mutation",
      test_name: "trusted key bytes accept the exact limit and reject the first excess",
      assertion: "assert {:error, %Error{code: :invalid_key}} = HMAC.sign"
    },
    "signature" => %{
      path: "lib/ash_onetime/token.ex",
      original: "      signing_bytes = body_bytes",
      mutated:
        "      signing_bytes = (case body_bytes do <<first, rest::binary>> -> <<Bitwise.bxor(first, 1), rest::binary>> end)",
      test: "test/ash_onetime/token_test.exs",
      tag: "signature_mutation",
      test_name: "signature binds the exact canonical body bytes",
      assertion: "assert {:ok, ^token} = Token.verify(encoded, KeyResolver, verify_options())"
    }
  }

  @registered @mutations |> Map.keys() |> MapSet.new()

  def main(["--self-test"]) do
    case validate(["unregistered-mutation"]) do
      {:error, ["unregistered-mutation"]} ->
        IO.puts("mutation checker self-test: unknown mutations fail closed")

      result ->
        IO.puts(:stderr, "mutation checker self-test failed: #{inspect(result)}")
        System.halt(1)
    end
  end

  def main(["--" | names]), do: main(names)

  def main(names) do
    case validate(names) do
      :ok ->
        Enum.each(names, &run_mutation!(&1, Map.fetch!(@mutations, &1)))
        IO.puts("mutation checks passed: #{Enum.join(names, ", ")}")

      {:error, unknown} ->
        IO.puts(:stderr, "unknown mutation checks: #{Enum.join(unknown, ", ")}")
        System.halt(2)
    end
  rescue
    exception ->
      IO.puts(:stderr, Exception.message(exception))
      System.halt(1)
  end

  defp run_mutation!(name, mutation) do
    original_source = File.read!(mutation.path)
    assert_single_site!(original_source, mutation.original, mutation.path)

    mutated_source =
      String.replace(original_source, mutation.original, mutation.mutated, global: false)

    IO.puts("mutation #{name}: source edit #{mutation.original} -> #{mutation.mutated}")
    IO.puts("mutation #{name}: expected failing test: #{mutation.test_name}")
    IO.puts("mutation #{name}: expected failing assertion: #{mutation.assertion}")

    {red_output, red_status} =
      try do
        File.write!(mutation.path, mutated_source)
        run_test(mutation)
      after
        File.write!(mutation.path, original_source)
      end

    IO.puts("mutation #{name}: mutant command output follows")
    IO.puts(red_output)

    if red_status == 0 do
      raise "mutation #{name} survived its owned test"
    end

    unless String.contains?(red_output, mutation.test_name) and
             String.contains?(red_output, mutation.assertion) do
      raise "mutation #{name} failed without its named assertion"
    end

    unless File.read!(mutation.path) == original_source do
      raise "mutation #{name} did not restore exact source bytes"
    end

    {restored_output, restored_status} = run_test(mutation)
    IO.puts("mutation #{name}: restored command output follows")
    IO.puts(restored_output)

    if restored_status != 0 do
      raise "mutation #{name} did not return green after restoration"
    end

    IO.puts("mutation #{name}: RED confirmed; exact source bytes restored; tagged test GREEN")
  end

  defp assert_single_site!(source, needle, path) do
    case :binary.matches(source, needle) do
      [_single] -> :ok
      matches -> raise "mutation site count for #{path} was #{length(matches)}, expected 1"
    end
  end

  defp run_test(mutation) do
    env =
      case System.get_env("MIX_BUILD_PATH") do
        nil ->
          [{"MIX_ENV", "test"}, {"DATABASE_URL", @database_url}]

        build_path ->
          [{"MIX_BUILD_PATH", build_path}, {"MIX_ENV", "test"}, {"DATABASE_URL", @database_url}]
      end

    System.cmd(
      "mix",
      ["test", "--force", mutation.test, "--only", mutation.tag, "--seed", "0"],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp validate([]), do: {:error, ["no mutation checks requested"]}

  defp validate(names) do
    unknown = Enum.reject(names, &MapSet.member?(@registered, &1))
    if unknown == [], do: :ok, else: {:error, unknown}
  end
end

AshOnetime.MutationCheck.main(System.argv())
