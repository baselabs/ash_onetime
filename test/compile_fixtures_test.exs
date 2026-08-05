Code.require_file(Path.join(__DIR__, "compile_fixtures/support.exs"))

defmodule AshOnetime.CompileFixturesTest do
  use ExUnit.Case, async: false

  alias AshOnetime.CompileFixture.FreshMinter

  @fixtures %{
    "missing_strategy.exs" => AshOnetime.CompileFixtures.MissingStrategy,
    "empty_scope.exs" => AshOnetime.CompileFixtures.EmptyScope,
    "missing_scope.exs" => AshOnetime.CompileFixtures.MissingScope,
    "missing_action.exs" => AshOnetime.CompileFixtures.MissingAction,
    "read_action.exs" => AshOnetime.CompileFixtures.ReadAction,
    "non_postgres.exs" => AshOnetime.CompileFixtures.NonPostgres,
    "nontransactional_action.exs" => AshOnetime.CompileFixtures.NontransactionalAction,
    "nontransactional_generic.exs" => AshOnetime.CompileFixtures.NontransactionalGeneric,
    "nonce_response.exs" => AshOnetime.CompileFixtures.NonceResponse,
    "nonce_failure_option.exs" => AshOnetime.CompileFixtures.NonceFailureOption,
    "unverified_nonce_key.exs" => AshOnetime.CompileFixtures.UnverifiedNonceKey,
    "separated_hmac_trust.exs" => AshOnetime.CompileFixtures.SeparatedHmacTrust,
    "unsafe_relationship.exs" => AshOnetime.CompileFixtures.UnsafeRelationship,
    "unsafe_hook.exs" => AshOnetime.CompileFixtures.UnsafeHook,
    "unsafe_global_hook.exs" => AshOnetime.CompileFixtures.UnsafeGlobalHook,
    "unsafe_pipeline_hook.exs" => AshOnetime.CompileFixtures.UnsafePipelineHook,
    "external_nonce.exs" => AshOnetime.CompileFixtures.ExternalNonce,
    "unwrappable_generic.exs" => AshOnetime.CompileFixtures.UnwrappableGeneric,
    "duplicate_protection.exs" => AshOnetime.CompileFixtures.DuplicateProtection,
    "excessive_bounds.exs" => AshOnetime.CompileFixtures.ExcessiveBounds,
    "missing_callbacks.exs" => AshOnetime.CompileFixtures.MissingCallbacks,
    "wrong_execute_arity_external.exs" => AshOnetime.CompileFixtures.WrongExecuteArityExternal,
    "wrong_recover_arity_external.exs" => AshOnetime.CompileFixtures.WrongRecoverArityExternal,
    "external_untracked.exs" => AshOnetime.CompileFixtures.ExternalUntracked,
    "reserved_arguments.exs" => AshOnetime.CompileFixtures.ReservedArguments,
    "reserved_attributes.exs" => AshOnetime.CompileFixtures.ReservedAttributes,
    "reserved_argument_key.exs" => AshOnetime.CompileFixtures.ReservedArgumentKey,
    "reserved_argument_issued_at.exs" => AshOnetime.CompileFixtures.ReservedArgumentIssuedAt,
    "reserved_argument_expires_at.exs" => AshOnetime.CompileFixtures.ReservedArgumentExpiresAt,
    "reserved_argument_algorithm.exs" => AshOnetime.CompileFixtures.ReservedArgumentAlgorithm,
    "reserved_attribute_key.exs" => AshOnetime.CompileFixtures.ReservedAttributeKey,
    "reserved_attribute_issued_at.exs" => AshOnetime.CompileFixtures.ReservedAttributeIssuedAt,
    "reserved_attribute_expires_at.exs" => AshOnetime.CompileFixtures.ReservedAttributeExpiresAt,
    "reserved_attribute_verification_state.exs" =>
      AshOnetime.CompileFixtures.ReservedAttributeVerificationState,
    "missing_key_reference.exs" => AshOnetime.CompileFixtures.MissingKeyReference,
    "missing_external_reference.exs" => AshOnetime.CompileFixtures.MissingExternalReference,
    "unsafe_builtin_option.exs" => AshOnetime.CompileFixtures.UnsafeBuiltinOption,
    "unsafe_validation.exs" => AshOnetime.CompileFixtures.UnsafeValidation
  }

  @fixture_expectations %{
    "missing_strategy.exs" => {:charge, :strategy, "strategy is required and has no default", 6},
    "empty_scope.exs" => {:charge, :scope, "scope must contain at least one component", 8},
    "missing_scope.exs" => {:charge, :scope, "scope is required and has no global fallback", 6},
    "missing_action.exs" => {:missing, :action, "protected action :missing does not exist", 6},
    "read_action.exs" => {:lookup, :action, "read actions cannot be protected", 6},
    "non_postgres.exs" =>
      {:charge, :action, "protected actions require AshPostgres.DataLayer", 7},
    "nontransactional_action.exs" =>
      {:charge, :action, "protected action must set transaction? true", 7},
    "nontransactional_generic.exs" =>
      {:redeem, :action, "protected action must set transaction? true", 7},
    "nonce_response.exs" => {:redeem, :response, "nonce has no stored-response surface", 6},
    "nonce_failure_option.exs" =>
      {:redeem, :on_definite_store_failure,
       "nonce failure direction is fixed to fail closed and cannot be configured", 11},
    "unverified_nonce_key.exs" =>
      {:redeem, :key, "nonce keys must contain only verified or minted trusted sources", 9},
    "separated_hmac_trust.exs" =>
      {:redeem, :key,
       "trusted key module has an invalid algorithm/trust model; separated HMAC is forbidden", 9},
    "unsafe_relationship.exs" =>
      {:charge, :action, "managed relationships are unsafe for idempotent replay", 7},
    "unsafe_hook.exs" =>
      {:charge, :action, "AshOnetime.CompileFixture.UnsafeChange must export replay_safety/1", 6},
    "unsafe_global_hook.exs" =>
      {:charge, :action, "AshOnetime.CompileFixture.UnsafeChange must export replay_safety/1", 7},
    "unsafe_pipeline_hook.exs" =>
      {:charge, :action, "AshOnetime.CompileFixture.UnsafeChange must export replay_safety/1", 8},
    "external_nonce.exs" =>
      {:redeem, :external_effect, "nonce cannot configure external effects", 11},
    "unwrappable_generic.exs" =>
      {:redeem, :action, "generic action run must be a module-based implementation", 7},
    "duplicate_protection.exs" =>
      {:redeem, :action, "action :redeem can be protected only once", 6},
    "excessive_bounds.exs" => {:charge, :retention, "must be a positive bounded duration", 12},
    "missing_callbacks.exs" =>
      {:redeem, :scope,
       "AshOnetime.CompileFixture.UnsafeChange is missing callbacks [resolve: 2]", 8},
    "wrong_execute_arity_external.exs" =>
      {:charge, :external_effect,
       "AshOnetime.CompileFixture.WrongExecuteArityExternal is missing callbacks [execute: 3]",
       13},
    "wrong_recover_arity_external.exs" =>
      {:charge, :external_effect,
       "AshOnetime.CompileFixture.WrongRecoverArityExternal is missing callbacks [recover: 3]",
       13},
    "external_untracked.exs" =>
      {:charge, :on_definite_store_failure,
       "external effects require a committed recovery point and cannot execute untracked", 14},
    "reserved_arguments.exs" =>
      {:charge, :action,
       "protected action exposes reserved verification inputs: [:verification_state]", 7},
    "reserved_attributes.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:algorithm]", 8},
    "reserved_argument_key.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:key]", 7},
    "reserved_argument_issued_at.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:issued_at]", 7},
    "reserved_argument_expires_at.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:expires_at]",
       7},
    "reserved_argument_algorithm.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:algorithm]", 7},
    "reserved_attribute_key.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:key]", 8},
    "reserved_attribute_issued_at.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:issued_at]", 8},
    "reserved_attribute_expires_at.exs" =>
      {:charge, :action, "protected action exposes reserved verification inputs: [:expires_at]",
       8},
    "reserved_attribute_verification_state.exs" =>
      {:charge, :action,
       "protected action exposes reserved verification inputs: [:verification_state]", 8},
    "missing_key_reference.exs" =>
      {:charge, :key, "references missing arguments [:missing_key] or attributes []", 9},
    "missing_external_reference.exs" =>
      {:charge, :key, "references missing arguments [:missing_external_key] or attributes []", 9},
    "unsafe_builtin_option.exs" =>
      {:charge, :action, "set_attribute value must be literal for idempotent replay", 7},
    "unsafe_validation.exs" =>
      {:charge, :action,
       "AshOnetime.CompileFixture.UnsafeValidation must export replay_safety/1 for idempotent replay validation",
       7}
  }

  @matrix_expectations %{
    missing_scope_callback:
      {:redeem, :scope,
       "AshOnetime.CompileFixture.UnsafeChange is missing callbacks [resolve: 2]"},
    missing_verifier_callback:
      {:redeem, :key,
       "AshOnetime.CompileFixture.MissingVerifier is missing callbacks [verify: 2]"},
    missing_minter_callback:
      {:redeem, :key, "AshOnetime.CompileFixture.MissingMinter is missing callbacks [mint: 1]"},
    invalid_verifier_algorithm:
      {:redeem, :key,
       "trusted key module has an invalid algorithm/trust model; separated HMAC is forbidden"},
    invalid_verifier_trust:
      {:redeem, :key,
       "trusted key module has an invalid algorithm/trust model; separated HMAC is forbidden"},
    separated_hmac_minter:
      {:redeem, :key,
       "trusted key module has an invalid algorithm/trust model; separated HMAC is forbidden"},
    missing_codec_callback:
      {:charge, :response,
       "AshOnetime.CompileFixture.MissingCodec is missing callbacks [decode: 4]"},
    missing_classifier_callback:
      {:charge, :response,
       "AshOnetime.CompileFixture.MissingClassifier is missing callbacks [classify: 2]"},
    empty_codec_tag:
      {:charge, :response,
       "AshOnetime.CompileFixture.EmptyTagCodec returned an invalid format tag"},
    colon_codec_tag:
      {:charge, :response,
       "AshOnetime.CompileFixture.ColonTagCodec returned an invalid format tag"},
    long_codec_tag:
      {:charge, :response,
       "AshOnetime.CompileFixture.LongTagCodec returned an invalid format tag"},
    missing_external_callback:
      {:charge, :external_effect,
       "AshOnetime.CompileFixture.MissingExternal is missing callbacks [recover: 3]"},
    response_duplicate_fields:
      {:charge, :response, "response fields must not contain duplicates"},
    response_private_field:
      {:charge, :response,
       "response field :private_note must be a public non-sensitive attribute"},
    response_sensitive_field:
      {:charge, :response, "response field :secret_note must be a public non-sensitive attribute"},
    response_reserved_field:
      {:charge, :response, "response fields must not contain reserved names"},
    response_relationship_field:
      {:charge, :response, "response field :owner must be a public non-sensitive attribute"},
    response_unknown_field:
      {:charge, :response, "response field :unknown must be a public non-sensitive attribute"},
    unsafe_global_relationship:
      {:charge, :action, "managed relationships are unsafe for idempotent replay"},
    unsafe_pipeline_relationship:
      {:charge, :action, "managed relationships are unsafe for idempotent replay"},
    unsafe_inline_change:
      {:charge, :action, "inline lifecycle callbacks cannot declare replay safety"},
    crud_notifier:
      {:charge, :action, "notifier delivery is unsupported for protected CRUD actions"},
    local_around_action:
      {:charge, :action,
       "AshOnetime.CompileFixture.AroundChange declares an additional around-action boundary"},
    global_around_action:
      {:charge, :action,
       "AshOnetime.CompileFixture.AroundChange declares an additional around-action boundary"},
    nonce_local_around_action:
      {:charge, :action,
       "AshOnetime.CompileFixture.AroundChange declares an additional around-action boundary"},
    nonce_global_around_action:
      {:charge, :action,
       "AshOnetime.CompileFixture.AroundChange declares an additional around-action boundary"},
    pure_notification_producer:
      {:charge, :action,
       "AshOnetime.CompileFixture.PureNotificationChange declares notification/effect capabilities incompatible with :pure"},
    global_pure_notification_producer:
      {:charge, :action,
       "AshOnetime.CompileFixture.PureNotificationChange declares notification/effect capabilities incompatible with :pure"},
    unclassified_notification_producer:
      {:charge, :action,
       "AshOnetime.CompileFixture.UnclassifiedProducerChange must export replay_capabilities/1"},
    marker_blind_notification_producer:
      {:charge, :action,
       "AshOnetime.CompileFixture.MarkerBlindProducerChange must consume the replay marker and declare closed capabilities"},
    invalid_change_declaration:
      {:charge, :action,
       "AshOnetime.CompileFixture.InvalidSafetyChange returned an invalid replay safety declaration"},
    unsafe_local_preparation:
      {:redeem, :action,
       "AshOnetime.CompileFixture.UnsafePreparation must export replay_safety/1"},
    invalid_preparation_declaration:
      {:redeem, :action,
       "AshOnetime.CompileFixture.InvalidSafetyPreparation returned an invalid replay safety declaration"},
    unsafe_inline_preparation:
      {:redeem, :action, "inline lifecycle callbacks cannot declare replay safety"},
    unsafe_global_preparation:
      {:redeem, :action,
       "AshOnetime.CompileFixture.UnsafePreparation must export replay_safety/1"},
    unsafe_pipeline_preparation:
      {:redeem, :action,
       "AshOnetime.CompileFixture.UnsafePreparation must export replay_safety/1"},
    unsafe_set_context_change:
      {:charge, :action, "set_context context must be literal for idempotent replay"},
    unsafe_set_context_preparation:
      {:redeem, :action, "set_context context must be literal for idempotent replay"},
    unsafe_relate_actor: {:charge, :action, "relating the actor is unsafe for idempotent replay"},
    nonce_client_key:
      {:redeem, :key, "nonce keys must contain only verified or minted trusted sources"},
    nonce_argument_key:
      {:redeem, :key, "nonce keys must contain only verified or minted trusted sources"},
    nonce_attribute_key: {:redeem, :key, "generic actions cannot reference attributes"},
    nonce_external_key:
      {:redeem, :key, "nonce keys must contain only verified or minted trusted sources"},
    nonce_mixed_key:
      {:redeem, :key, "nonce keys must contain only verified or minted trusted sources"},
    nonce_minted_composite: {:redeem, :key, "a minted nonce key must be the only key source"},
    nonce_fingerprint: {:redeem, :fingerprint, "nonce has no fingerprint surface"},
    nonce_retention: {:redeem, :retention, "nonce retention derives from its window"},
    nonce_external_create: {:charge, :external_effect, "nonce cannot configure external effects"},
    nonce_external_update: {:adjust, :external_effect, "nonce cannot configure external effects"},
    nonce_external_destroy:
      {:remove, :external_effect, "nonce cannot configure external effects"},
    nonce_external_generic:
      {:redeem, :external_effect, "nonce cannot configure external effects"},
    limit_max_key_bytes:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_max_token_bytes:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_max_scope_components:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_max_fingerprint_bytes:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_max_response_bytes:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_verifier_timeout_ms:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_max_cache_entry_bytes:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_zero:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_negative:
      {:charge, :limits, "limit overrides must be positive and cannot exceed package ceilings"},
    limit_unknown: {:charge, :limits, "unknown limit options: [:unknown_bound]"},
    scope_over_configured_limit:
      {:charge, :scope, "scope has 2 components but max_scope_components is 1"},
    retention_negative: {:charge, :retention, "must be a positive bounded duration"},
    retention_tuple_negative: {:charge, :retention, "must be a positive bounded duration"},
    window_negative_age:
      {:redeem, :window, "nonce window requires bounded nonnegative max_age and clock_skew"},
    window_negative_skew:
      {:redeem, :window, "nonce window requires bounded nonnegative max_age and clock_skew"},
    window_sum_overflow:
      {:redeem, :window, "nonce window requires bounded nonnegative max_age and clock_skew"},
    reactor_generic:
      {:redeem, :action, "generic action run must be a module-based implementation"},
    unsafe_function_validation:
      {:charge, :action, "inline validation functions are unsafe for idempotent replay"},
    unsafe_compare_validation:
      {:charge, :action, "compare validation option :greater_than must be literal"},
    unsafe_nested_validation:
      {:charge, :action,
       "AshOnetime.CompileFixture.UnsafeValidation must export replay_safety/1 for idempotent replay validation"},
    unsafe_where_validation:
      {:charge, :action,
       "AshOnetime.CompileFixture.UnsafeValidation must export replay_safety/1 for idempotent replay validation"},
    unsafe_global_validation:
      {:charge, :action,
       "AshOnetime.CompileFixture.UnsafeValidation must export replay_safety/1 for idempotent replay validation"},
    unsafe_pipeline_validation:
      {:charge, :action,
       "AshOnetime.CompileFixture.UnsafeValidation must export replay_safety/1 for idempotent replay validation"}
  }

  @runner ~S"""
  [fixture, expected] = System.argv()
  expected = Module.concat([expected])
  Code.require_file(Path.join(Path.dirname(fixture), "support.exs"))

  emit_dsl_error = fn %Spark.Error.DslError{} = error ->
    path = Enum.map_join(error.path, " -> ", &to_string/1)
    message = if is_binary(error.message), do: error.message, else: inspect(error.message)
    file = error.location |> :erl_anno.file() |> to_string() |> Path.relative_to_cwd()
    location = error.location |> :erl_anno.location() |> then(fn {line, _column} -> line; line -> line end)
    IO.puts("ASH_ONETIME_FIXTURE_PATH=#{path}")
    IO.puts("ASH_ONETIME_FIXTURE_MESSAGE=#{message}")
    IO.puts("ASH_ONETIME_FIXTURE_LOCATION=#{file}:#{location}")
  end

  try do
    Code.compile_file(fixture)
    IO.puts("ASH_ONETIME_FIXTURE_RESULT=compiled")
    IO.puts("ASH_ONETIME_FIXTURE_LOADED=#{Code.ensure_loaded?(expected)}")
    System.halt(0)
  rescue
    error in Spark.Error.DslError ->
      IO.puts("ASH_ONETIME_FIXTURE_RESULT=rejected")
      IO.puts("ASH_ONETIME_FIXTURE_LOADED=#{Code.ensure_loaded?(expected)}")
      emit_dsl_error.(error)
      IO.puts(Exception.format(:error, error, __STACKTRACE__))
      System.halt(1)
  end
  """

  @matrix_runner ~S"""
  [case_name] = System.argv()
  fixture_dir = Path.expand("test/compile_fixtures")
  Code.require_file(Path.join(fixture_dir, "support.exs"))
  Code.require_file(Path.join(fixture_dir, "matrix_cases.exs"))
  case_name = String.to_existing_atom(case_name)
  expected = AshOnetime.CompileFixture.MatrixCases.module(case_name)

  emit_dsl_error = fn %Spark.Error.DslError{} = error ->
    path = Enum.map_join(error.path, " -> ", &to_string/1)
    message = if is_binary(error.message), do: error.message, else: inspect(error.message)
    file = error.location |> :erl_anno.file() |> to_string() |> Path.relative_to_cwd()
    location = error.location |> :erl_anno.location() |> then(fn {line, _column} -> line; line -> line end)
    IO.puts("ASH_ONETIME_FIXTURE_PATH=#{path}")
    IO.puts("ASH_ONETIME_FIXTURE_MESSAGE=#{message}")
    IO.puts("ASH_ONETIME_FIXTURE_LOCATION=#{file}:#{location}")
  end

  try do
    AshOnetime.CompileFixture.MatrixCases.compile(case_name)
    IO.puts("ASH_ONETIME_FIXTURE_RESULT=compiled")
    IO.puts("ASH_ONETIME_FIXTURE_LOADED=#{Code.ensure_loaded?(expected)}")
    System.halt(0)
  rescue
    error in Spark.Error.DslError ->
      IO.puts("ASH_ONETIME_FIXTURE_RESULT=rejected")
      IO.puts("ASH_ONETIME_FIXTURE_LOADED=#{Code.ensure_loaded?(expected)}")
      emit_dsl_error.(error)
      IO.puts(Exception.format(:error, error, __STACKTRACE__))
      System.halt(1)
  end
  """

  for {fixture, expected} <- @fixtures do
    @tag fixture: fixture
    test "rejects #{fixture} before the resource module loads" do
      fixture = unquote(fixture)
      expected = unquote(expected)
      {output, status} = run_fixture(fixture, expected)
      {action, option, message, line} = Map.fetch!(@fixture_expectations, fixture)

      assert status != 0, output
      assert fixture_fact(output, "RESULT") == "rejected"
      assert fixture_fact(output, "LOADED") == "false"
      assert fixture_fact(output, "PATH") == "onetime -> protect -> #{action} -> #{option}"
      assert fixture_fact(output, "MESSAGE") == message
      assert fixture_fact(output, "LOCATION") == "test/compile_fixtures/#{fixture}:#{line}"
    end
  end

  for {case_name, {action, option, message}} <- @matrix_expectations do
    @tag matrix_case: case_name
    test "rejects matrix case #{case_name} at its semantic option" do
      case_name = unquote(case_name)
      {output, status} = run_matrix_case(case_name)

      assert status != 0, output
      assert fixture_fact(output, "RESULT") == "rejected"
      assert fixture_fact(output, "LOADED") == "false"

      assert fixture_fact(output, "PATH") ==
               "onetime -> protect -> #{unquote(action)} -> #{unquote(option)}"

      assert fixture_fact(output, "MESSAGE") == unquote(message)
      assert fixture_fact(output, "LOCATION") == "test/compile_fixtures/matrix_cases.exs:12"
    end
  end

  @tag nonce_minted_composite_mutation: true
  test "a fresh minted nonce source cannot join a verified key" do
    assert {:ok, first} = FreshMinter.mint(%{})
    assert {:ok, second} = FreshMinter.mint(%{})
    refute first.key == second.key

    {output, status} = run_matrix_case(:nonce_minted_composite)
    assert status != 0, output
    assert output =~ "a minted nonce key must be the only key source"
  end

  @tag task5_notifier_guard_mutation: true
  test "protected CRUD actions reject notifier delivery at compile time" do
    {output, status} = run_matrix_case(:crud_notifier)

    assert status != 0, output
    assert fixture_fact(output, "RESULT") == "rejected"
    assert fixture_fact(output, "LOADED") == "false"
  end

  @tag task5_around_guard_mutation: true
  test "protected CRUD actions reject every additional around-action producer" do
    for case_name <- [
          :local_around_action,
          :global_around_action,
          :nonce_local_around_action,
          :nonce_global_around_action
        ] do
      {output, status} = run_matrix_case(case_name)
      assert status != 0, output
      assert fixture_fact(output, "RESULT") == "rejected"
    end
  end

  test "nonce CRUD requires only a closed around-action capability declaration" do
    {output, status} = run_matrix_case(:nonce_non_around_capability)

    assert status == 0, output
    assert fixture_fact(output, "RESULT") == "compiled"
    assert fixture_fact(output, "LOADED") == "true"
  end

  @tag task5_capability_guard_mutation: true
  test "lifecycle notification and effect capability declarations fail closed" do
    for case_name <- [
          :pure_notification_producer,
          :global_pure_notification_producer,
          :unclassified_notification_producer,
          :marker_blind_notification_producer
        ] do
      {output, status} = run_matrix_case(case_name)
      assert status != 0, output
      assert fixture_fact(output, "RESULT") == "rejected"
    end
  end

  @tag :dsl_idempotency_mutation
  test "idempotency requires replay contracts" do
    assert_rejected("excessive_bounds.exs", AshOnetime.CompileFixtures.ExcessiveBounds)
  end

  @tag :dsl_nonce_mutation
  test "nonce rejects replay response configuration" do
    assert_rejected("nonce_response.exs", AshOnetime.CompileFixtures.NonceResponse)
  end

  @tag :dsl_nonce_key_mutation
  test "nonce requires trusted key sources" do
    assert_rejected("unverified_nonce_key.exs", AshOnetime.CompileFixtures.UnverifiedNonceKey)
  end

  @tag :dsl_lifecycle_mutation
  test "idempotency rejects replay-unsafe lifecycle callbacks" do
    assert_rejected("unsafe_hook.exs", AshOnetime.CompileFixtures.UnsafeHook)
  end

  @tag :dsl_duplicate_mutation
  test "duplicate protection is transformer-owned" do
    assert_rejected("duplicate_protection.exs", AshOnetime.CompileFixtures.DuplicateProtection)
  end

  @tag :dsl_references_mutation
  test "key sources must reference declared action inputs" do
    assert_rejected("missing_key_reference.exs", AshOnetime.CompileFixtures.MissingKeyReference)
  end

  @tag :dsl_builtin_options_mutation
  test "replay-safe built-ins require literal options" do
    assert_rejected("unsafe_builtin_option.exs", AshOnetime.CompileFixtures.UnsafeBuiltinOption)
  end

  @tag :dsl_validations_mutation
  test "idempotency rejects replay-unsafe validations" do
    assert_rejected("unsafe_validation.exs", AshOnetime.CompileFixtures.UnsafeValidation)
  end

  def run_fixture(fixture, expected) do
    fixture = Path.expand(Path.join("test/compile_fixtures", fixture))

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      "elixir",
      code_paths ++ ["-e", @runner, "--", fixture, inspect(expected)],
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}]
    )
  end

  def run_matrix_case(case_name) do
    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      "elixir",
      code_paths ++ ["-e", @matrix_runner, "--", Atom.to_string(case_name)],
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}]
    )
  end

  defp assert_rejected(fixture, expected) do
    {output, status} = run_fixture(fixture, expected)

    assert status != 0, output
    assert output =~ "ASH_ONETIME_FIXTURE_RESULT=rejected"
    assert output =~ "ASH_ONETIME_FIXTURE_LOADED=false"
  end

  defp fixture_fact(output, name) do
    prefix = "ASH_ONETIME_FIXTURE_#{name}="

    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> case do
      [fact] -> String.replace_prefix(fact, prefix, "")
      facts -> flunk("expected exactly one #{prefix} marker, got #{inspect(facts)}\n#{output}")
    end
  end
end
