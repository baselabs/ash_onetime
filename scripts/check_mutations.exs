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
    },
    "dsl-idempotency" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_idempotency(protection, context),\n    do: verify_idempotency_details(protection, context)",
      mutated: "  defp verify_idempotency(protection, _context), do: {:ok, protection}",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_idempotency_mutation",
      test_name: "idempotency requires replay contracts",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"excessive_bounds.exs", "AshOnetime.CompileFixtures.ExcessiveBounds"}
    },
    "dsl-nonce" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_nonce(protection, context), do: verify_nonce_details(protection, context)",
      mutated: "  defp verify_nonce(protection, _context), do: {:ok, protection}",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_nonce_mutation",
      test_name: "nonce rejects replay response configuration",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"nonce_response.exs", "AshOnetime.CompileFixtures.NonceResponse"}
    },
    "dsl-nonce-key" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_nonce_key(protection, context), do: verify_nonce_key_details(protection, context)",
      mutated: "  defp verify_nonce_key(_protection, _context), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_nonce_key_mutation",
      test_name: "nonce requires trusted key sources",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unverified_nonce_key.exs", "AshOnetime.CompileFixtures.UnverifiedNonceKey"}
    },
    "dsl-lifecycle" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_lifecycle(protection, context), do: verify_lifecycle_details(protection, context)",
      mutated: "  defp verify_lifecycle(_protection, _context), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_lifecycle_mutation",
      test_name: "idempotency rejects replay-unsafe lifecycle callbacks",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unsafe_hook.exs", "AshOnetime.CompileFixtures.UnsafeHook"}
    },
    "dsl-duplicate" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp reject_duplicates(protections, dsl_state),\n    do: reject_duplicate_details(protections, dsl_state)",
      mutated: "  defp reject_duplicates(_protections, _dsl_state), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_duplicate_mutation",
      test_name: "duplicate protection is transformer-owned",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"duplicate_protection.exs", "AshOnetime.CompileFixtures.DuplicateProtection"}
    },
    "dsl-references" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_references(references, protection, context, option),\n    do: verify_reference_details(references, protection, context, option)",
      mutated: "  defp verify_references(_references, _protection, _context, _option), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_references_mutation",
      test_name: "key sources must reference declared action inputs",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"missing_key_reference.exs", "AshOnetime.CompileFixtures.MissingKeyReference"}
    },
    "dsl-builtin-options" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_replay_ref(ref, allowlist), do: verify_replay_ref_details(ref, allowlist)",
      mutated: "  defp verify_replay_ref(_ref, _allowlist), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_builtin_options_mutation",
      test_name: "replay-safe built-ins require literal options",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unsafe_builtin_option.exs", "AshOnetime.CompileFixtures.UnsafeBuiltinOption"}
    },
    "dsl-validations" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_replay_validation(validation), do: verify_replay_validation_details(validation)",
      mutated: "  defp verify_replay_validation(_validation), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_validations_mutation",
      test_name: "idempotency rejects replay-unsafe validations",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unsafe_validation.exs", "AshOnetime.CompileFixtures.UnsafeValidation"}
    },
    "unique-constraint" => %{
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original: "@collision_constraint \"UNIQUE (operation_hash, scope_hash, key_hash)\"",
      mutated: "@collision_constraint \"CHECK (true)\"",
      test: "test/ash_onetime/store/contention_test.exs",
      tag: "unique_constraint_mutation",
      test_name: "idempotency collision waits on the committed winner and appends one effect",
      assertion: "assert ledger_count(observer, prefix, request) == 1"
    },
    "cleanup-boundary" => %{
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original: "@cleanup_comparator \">\"",
      mutated: "@cleanup_comparator \">=\"",
      test: "test/ash_onetime/store/cleanup_test.exs",
      tag: "cleanup_boundary_mutation",
      test_name:
        "cleanup predicate, function, and parent triggers are strict at the retention boundary",
      assertion: "assert %{rows: [[false]]}"
    },
    "operation-hash-select" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "@logical_key_predicate \"operation_hash = $1 AND scope_hash = $2 AND key_hash = $3\"",
      mutated:
        "@logical_key_predicate \"$1::bytea IS NOT NULL AND operation_hash = operation_hash AND scope_hash = $2 AND key_hash = $3\"",
      test: "test/ash_onetime/store/uncertainty_test.exs",
      tag: "operation_hash_select_mutation",
      test_name: "operation hash remains part of the shared command-two and load sink",
      assertion: "assert {:ok, %Result{status: :processing, claim: collision}}"
    },
    "operation-hash-completion" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "@completion_key_predicate \"operation_hash = $4 AND scope_hash = $5 AND key_hash = $6\"",
      mutated:
        "@completion_key_predicate \"$4::bytea IS NOT NULL AND operation_hash = operation_hash AND scope_hash = $5 AND key_hash = $6\"",
      test: "test/ash_onetime/store/partition_test.exs",
      tag: "operation_hash_completion_mutation",
      test_name: "completion update keeps operation identity when hash partitions share an id",
      assertion: "assert {:ok, %Result{status: :complete, claim: complete}}"
    },
    "operation-hash-cleanup" => %{
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original:
        "@cleanup_delete_predicate \"claims.operation_hash = candidates.operation_hash AND claims.id = candidates.id\"",
      mutated:
        "@cleanup_delete_predicate \"candidates.operation_hash = candidates.operation_hash AND claims.id = candidates.id\"",
      test: "test/ash_onetime/store/partition_test.exs",
      tag: "operation_hash_cleanup_mutation",
      test_name: "cleanup delete keeps operation identity when hash partitions share an id",
      assertion: "assert {:ok, %{idempotency: 1, nonce: 0}}"
    },
    "response-field-guard" => %{
      path: "lib/ash_onetime/codec/resource.ex",
      original: "    MapSet.new(actual) == MapSet.new(Enum.map(expected, &Atom.to_string/1))",
      mutated: "    true",
      test: "test/ash_onetime/codec/resource_test.exs",
      tag: "response_allowlist_mutation",
      test_name: "undeclared sentinel private payload field is terminal",
      assertion: "assert {:error, %Error{code: :response_fields_invalid}} ="
    },
    "return-contract" => %{
      path: "test/support/resources/result_examples.ex",
      original: "    action :nullable_result, :string do",
      mutated: "    action :nullable_result, :uuid do",
      test: "test/ash_onetime/codec/response_test.exs",
      tag: "return_type_mutation",
      test_name: "fixed bytes bind the live return contract before custom decode",
      assertion: "assert {:ok, \"fixed\"} = Response.replay(store_result(fixed), contract, [])"
    }
  }

  @groups %{
    "response-allowlist" => ["response-field-guard"],
    "return-type" => ["return-contract"],
    "dsl-verifiers" => [
      "dsl-idempotency",
      "dsl-nonce",
      "dsl-nonce-key",
      "dsl-lifecycle",
      "dsl-duplicate",
      "dsl-references",
      "dsl-builtin-options",
      "dsl-validations"
    ],
    "operation-hash" => [
      "operation-hash-select",
      "operation-hash-completion",
      "operation-hash-cleanup"
    ]
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
    names = Enum.flat_map(names, &Map.get(@groups, &1, [&1]))

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
        probe_fixture!(name, mutation)
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

  defp probe_fixture!(_name, %{probe: nil}), do: :ok

  defp probe_fixture!(name, %{probe: {fixture, expected}}) do
    fixture = Path.expand(Path.join("test/compile_fixtures", fixture))
    env = [{"MIX_ENV", "test"}, {"DATABASE_URL", @database_url}]

    {compile_output, compile_status} =
      System.cmd("mix", ["compile", "--force"], env: env, stderr_to_stdout: true)

    if compile_status != 0 do
      raise "mutation #{name} failed to compile:\n#{compile_output}"
    end

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "scripts/probe_compile_fixture.exs", fixture, expected],
        env: env,
        stderr_to_stdout: true
      )

    IO.puts("mutation #{name}: direct fixture probe output follows")
    IO.puts(output)

    unless status == 0 and output =~ "ASH_ONETIME_FIXTURE_RESULT=compiled" and
             output =~ "ASH_ONETIME_FIXTURE_LOADED=true" do
      raise "mutation #{name} did not make its owned fixture compile and load"
    end
  end

  defp probe_fixture!(_name, _mutation), do: :ok

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
