defmodule AshOnetime.CompileFixture.MatrixCases do
  @moduledoc false

  alias AshOnetime.CompileFixture

  @fixture_file Path.expand("matrix_cases.exs", __DIR__)
  @line 12

  def module(case_name) do
    suffix = case_name |> Atom.to_string() |> Macro.camelize()
    Module.concat([AshOnetime.CompileFixtures.Matrix, suffix])
  end

  def compile(case_name) do
    {resource_options, protection} = definition(case_name)
    module = module(case_name)

    quoted =
      quote line: @line do
        require CompileFixture

        CompileFixture.resource unquote(module), unquote(resource_options) do
          onetime do
            unquote(protection_ast(protection))
          end
        end
      end

    Code.compile_quoted(quoted, @fixture_file)
  end

  defp definition(:missing_scope_callback) do
    {[], nonce(scope: [{:tenant, CompileFixture.UnsafeChange}])}
  end

  defp definition(:missing_verifier_callback) do
    {[], nonce(key: {:verified, :proof, CompileFixture.MissingVerifier})}
  end

  defp definition(:missing_minter_callback) do
    {[], nonce(key: {:minted, CompileFixture.MissingMinter})}
  end

  defp definition(:invalid_verifier_algorithm) do
    {[], nonce(key: {:verified, :proof, CompileFixture.BadAlgorithm})}
  end

  defp definition(:invalid_verifier_trust) do
    {[], nonce(key: {:verified, :proof, CompileFixture.BadTrust})}
  end

  defp definition(:separated_hmac_minter) do
    {[], nonce(key: {:minted, CompileFixture.SeparatedHMAC})}
  end

  defp definition(:missing_codec_callback) do
    {[], idempotency(response: {CompileFixture.MissingCodec, response_opts()})}
  end

  defp definition(:missing_classifier_callback) do
    opts = Keyword.put(response_opts(), :classify, CompileFixture.MissingClassifier)
    {[], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:empty_codec_tag) do
    {[], idempotency(response: {CompileFixture.EmptyTagCodec, response_opts()})}
  end

  defp definition(:colon_codec_tag) do
    {[], idempotency(response: {CompileFixture.ColonTagCodec, response_opts()})}
  end

  defp definition(:long_codec_tag) do
    {[], idempotency(response: {CompileFixture.LongTagCodec, response_opts()})}
  end

  defp definition(:missing_external_callback) do
    {[], idempotency(external_effect: CompileFixture.MissingExternal)}
  end

  defp definition(:response_duplicate_fields) do
    opts = Keyword.put(response_opts(), :fields, [:account_id, :account_id])
    {[attributes: :response_fields], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:response_private_field) do
    opts = Keyword.put(response_opts(), :fields, [:private_note])
    {[attributes: :response_fields], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:response_sensitive_field) do
    opts = Keyword.put(response_opts(), :fields, [:secret_note])
    {[attributes: :response_fields], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:response_reserved_field) do
    opts = Keyword.put(response_opts(), :fields, [:__metadata__])
    {[attributes: :response_fields], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:response_relationship_field) do
    opts = Keyword.put(response_opts(), :fields, [:owner])
    {[attributes: :response_fields], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:response_unknown_field) do
    opts = Keyword.put(response_opts(), :fields, [:unknown])
    {[attributes: :response_fields], idempotency(response: {CompileFixture.Codec, opts})}
  end

  defp definition(:unsafe_global_relationship) do
    {[lifecycle: :global_relationship], idempotency()}
  end

  defp definition(:unsafe_pipeline_relationship) do
    {[lifecycle: :pipeline_relationship, actions: :pipeline_hook], idempotency()}
  end

  defp definition(:unsafe_inline_change) do
    {[actions: :inline_change], idempotency()}
  end

  defp definition(:crud_notifier) do
    {[actions: :notifier], idempotency()}
  end

  defp definition(:local_around_action) do
    {[actions: :around_change], idempotency()}
  end

  defp definition(:global_around_action) do
    {[lifecycle: :global_around], idempotency()}
  end

  defp definition(:nonce_local_around_action) do
    {[actions: :around_change], crud_nonce()}
  end

  defp definition(:nonce_global_around_action) do
    {[lifecycle: :global_around], crud_nonce()}
  end

  defp definition(:nonce_non_around_capability) do
    {[actions: :nonce_non_around], crud_nonce()}
  end

  defp definition(:pure_notification_producer) do
    {[actions: :pure_notification], idempotency()}
  end

  defp definition(:global_pure_notification_producer) do
    {[lifecycle: :global_pure_notification], idempotency()}
  end

  defp definition(:unclassified_notification_producer) do
    {[actions: :unclassified_producer], idempotency()}
  end

  defp definition(:marker_blind_notification_producer) do
    {[actions: :marker_blind], idempotency()}
  end

  defp definition(:invalid_change_declaration) do
    {[actions: :invalid_change], idempotency()}
  end

  defp definition(:unsafe_local_preparation) do
    {[actions: :unsafe_preparation], generic_idempotency()}
  end

  defp definition(:invalid_preparation_declaration) do
    {[actions: :invalid_preparation], generic_idempotency()}
  end

  defp definition(:unsafe_inline_preparation) do
    {[actions: :inline_preparation], generic_idempotency()}
  end

  defp definition(:unsafe_global_preparation) do
    {[lifecycle: :global_preparation], generic_idempotency()}
  end

  defp definition(:unsafe_pipeline_preparation) do
    {[lifecycle: :pipeline_preparation, actions: :pipeline_preparation], generic_idempotency()}
  end

  defp definition(:unsafe_set_context_change) do
    {[actions: :set_context_callable], idempotency()}
  end

  defp definition(:unsafe_set_context_preparation) do
    {[actions: :set_context_preparation], generic_idempotency()}
  end

  defp definition(:unsafe_relate_actor) do
    {[actions: :relate_actor], idempotency()}
  end

  defp definition(:nonce_client_key), do: {[], nonce(key: {:client, :proof})}
  defp definition(:nonce_argument_key), do: {[], nonce(key: {:argument, :proof})}
  defp definition(:nonce_attribute_key), do: {[], nonce(key: {:attribute, :account_id})}
  defp definition(:nonce_external_key), do: {[], nonce(key: {:external, :proof})}

  defp definition(:nonce_mixed_key) do
    {[], nonce(key: [{:verified, :proof, CompileFixture.Verifier}, {:client, :proof}])}
  end

  defp definition(:nonce_minted_composite) do
    {[],
     nonce(
       key: [
         {:verified, :proof, CompileFixture.Verifier},
         {:minted, CompileFixture.FreshMinter}
       ]
     )}
  end

  defp definition(:nonce_fingerprint), do: {[], nonce(fingerprint: [arguments: [:proof]])}
  defp definition(:nonce_retention), do: {[], nonce(retention: 60)}

  defp definition(:nonce_external_create) do
    {[actions: :external_nonce_matrix],
     nonce(
       action: :charge,
       key: {:verified, :idempotency_key, CompileFixture.Verifier},
       external_effect: CompileFixture.External
     )}
  end

  defp definition(:nonce_external_update) do
    {[actions: :external_nonce_matrix],
     nonce(action: :adjust, external_effect: CompileFixture.External)}
  end

  defp definition(:nonce_external_destroy) do
    {[actions: :external_nonce_matrix],
     nonce(action: :remove, external_effect: CompileFixture.External)}
  end

  defp definition(:nonce_external_generic) do
    {[actions: :external_nonce_matrix], nonce(external_effect: CompileFixture.External)}
  end

  defp definition(:limit_max_key_bytes),
    do: {[], idempotency(limits: [max_key_bytes: 4_097])}

  defp definition(:limit_max_token_bytes),
    do: {[], idempotency(limits: [max_token_bytes: 65_537])}

  defp definition(:limit_max_scope_components),
    do: {[], idempotency(limits: [max_scope_components: 17])}

  defp definition(:limit_max_fingerprint_bytes),
    do: {[], idempotency(limits: [max_fingerprint_bytes: 1_048_577])}

  defp definition(:limit_max_response_bytes),
    do: {[], idempotency(limits: [max_response_bytes: 16_777_217])}

  defp definition(:limit_verifier_timeout_ms),
    do: {[], idempotency(limits: [verifier_timeout_ms: 30_001])}

  defp definition(:limit_max_cache_entry_bytes),
    do: {[], idempotency(limits: [max_cache_entry_bytes: 16_777_217])}

  defp definition(:limit_zero), do: {[], idempotency(limits: [max_key_bytes: 0])}
  defp definition(:limit_negative), do: {[], idempotency(limits: [max_key_bytes: -1])}
  defp definition(:limit_unknown), do: {[], idempotency(limits: [unknown_bound: 1])}

  defp definition(:scope_over_configured_limit),
    do:
      {[],
       idempotency(scope: [{:static, "a"}, {:static, "b"}], limits: [max_scope_components: 1])}

  defp definition(:retention_negative), do: {[], idempotency(retention: -1)}
  defp definition(:retention_tuple_negative), do: {[], idempotency(retention: {-1, :second})}
  defp definition(:window_negative_age), do: {[], nonce(window: [max_age: -1, clock_skew: 0])}
  defp definition(:window_negative_skew), do: {[], nonce(window: [max_age: 1, clock_skew: -1])}

  defp definition(:window_sum_overflow) do
    {[], nonce(window: [max_age: 2_147_483_647, clock_skew: 1])}
  end

  defp definition(:reactor_generic) do
    {[actions: :reactor_generic], nonce()}
  end

  defp definition(:unsafe_function_validation) do
    {[actions: :unsafe_function_validation], idempotency()}
  end

  defp definition(:unsafe_compare_validation) do
    {[actions: :unsafe_compare_validation], idempotency()}
  end

  defp definition(:unsafe_nested_validation) do
    {[actions: :unsafe_nested_validation], idempotency()}
  end

  defp definition(:unsafe_where_validation) do
    {[actions: :unsafe_where_validation], idempotency()}
  end

  defp definition(:unsafe_global_validation) do
    {[lifecycle: :global_validation], idempotency()}
  end

  defp definition(:unsafe_pipeline_validation) do
    {[lifecycle: :pipeline_validation, actions: :pipeline_validation], idempotency()}
  end

  defp idempotency(overrides \\ []) do
    [
      action: :charge,
      strategy: :idempotency,
      scope: [{:static, "tenant"}],
      key: {:client, :idempotency_key},
      fingerprint: [arguments: [], attributes: [:account_id]],
      response: {CompileFixture.Codec, response_opts()},
      retention: 60
    ]
    |> Keyword.merge(overrides)
  end

  defp nonce(overrides \\ []) do
    [
      action: :redeem,
      strategy: :one_time_nonce,
      scope: [{:static, "tenant"}],
      key: {:verified, :proof, CompileFixture.Verifier},
      window: [max_age: 60, clock_skew: 5]
    ]
    |> Keyword.merge(overrides)
  end

  defp crud_nonce do
    nonce(
      action: :charge,
      key: {:verified, :idempotency_key, CompileFixture.Verifier}
    )
  end

  defp generic_idempotency do
    idempotency(
      action: :redeem,
      key: {:client, :proof},
      fingerprint: [arguments: [:proof], attributes: []]
    )
  end

  defp response_opts do
    [fields: [], classify: CompileFixture.Classifier]
  end

  defp protection_ast(protection) do
    {action, protection} = Keyword.pop!(protection, :action)

    clauses =
      Enum.map(protection, fn
        {:response, {codec, opts}} ->
          {:response, [line: @line], [Macro.escape(codec), Macro.escape(opts)]}

        {name, value} ->
          {name, [line: @line], [Macro.escape(value)]}
      end)

    {:protect, [line: @line], [action, [do: {:__block__, [line: @line], clauses}]]}
  end
end
