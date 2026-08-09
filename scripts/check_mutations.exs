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
    "window-newest" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(issued_at, newest) in [:eq, :lt]",
      mutated: "DateTime.compare(issued_at, newest) == :lt",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_newest_mutation",
      test_name: "newest replay-window endpoint is inclusive and the next tick is invalid",
      assertion: "assert :ok = Window.validate(newest, nil, @evaluated_at, 60, 5)"
    },
    "window-expiry-order" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(expires_at, issued_at) in [:eq, :gt] and",
      mutated: "DateTime.compare(expires_at, issued_at) == :gt and",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_expiry_order_mutation",
      test_name: "an expiry equal to issuance is the inclusive ordering edge and accepts",
      assertion:
        "assert :ok = Window.validate(@evaluated_at, @evaluated_at, @evaluated_at, 60, 5)"
    },
    "window-expiry-horizon" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(evaluated_at, expiry_horizon) in [:eq, :lt]",
      mutated: "DateTime.compare(evaluated_at, expiry_horizon) == :lt",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_expiry_horizon_mutation",
      test_name: "expiry is ordered and inclusive through skew",
      assertion: "assert :ok = Window.validate(issued_at, expires_at, @evaluated_at, 60, 5)"
    },
    "classifier-context-guard" => %{
      path: "lib/ash_onetime/response_classifier.ex",
      original:
        "def classify(classifier, value, context) when is_atom(classifier) and is_map(context) do",
      mutated: "def classify(classifier, value, context) when is_atom(classifier) do",
      test: "test/ash_onetime/response_classifier_test.exs",
      tag: "classifier_context_guard_mutation",
      test_name: "a non-map context fails closed before the classifier is invoked",
      assertion: "ResponseClassifier.classify(StoreClassifier, :secret, :not_a_map)"
    },
    "cache-fingerprint-conjunct" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "fixed_equal?(entry.fingerprint, claim.fingerprint)",
      mutated: "is_binary(entry.fingerprint)",
      test: "test/ash_onetime/cache_test.exs",
      tag: "cache_fingerprint_conjunct_mutation",
      test_name: "an entry whose fingerprint mismatches the claim degrades to stale",
      assertion: "assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)"
    },
    "cache-codec-conjunct" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "entry.codec == claim.response_codec",
      mutated: "is_binary(entry.codec)",
      test: "test/ash_onetime/cache_test.exs",
      tag: "cache_codec_conjunct_mutation",
      test_name: "an entry whose codec mismatches the claim degrades to stale",
      assertion: "assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)"
    },
    "cache-digest-conjunct" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "fixed_equal?(entry.digest, claim.response_digest)",
      mutated: "is_binary(entry.digest)",
      test: "test/ash_onetime/cache_test.exs",
      tag: "cache_digest_conjunct_mutation",
      test_name: "an entry whose digest field mismatches the claim degrades to stale",
      assertion: "assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)"
    },
    "cleanup-partition-limit-guard" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "partition_limit <= @max_partition_drops do",
      mutated: "partition_limit <= 999_999 do",
      test: "test/ash_onetime/store/cleanup_test.exs",
      tag: "cleanup_partition_limit_guard_mutation",
      test_name: "cleanup rejects out-of-range batch sizes and partition limits",
      assertion:
        "assert %Result{status: :failure, reason: :invalid_request} = Store.cleanup(target, 100, 129)"
    },
    "resource-relationship-leak" => %{
      path: "lib/ash_onetime/codec/resource.ex",
      original: "&relationship_unloaded?(value, &1, resource)",
      mutated: "fn _relationship -> true end",
      test: "test/ash_onetime/codec/resource_test.exs",
      tag: "resource_relationship_leak_mutation",
      test_name: "encode rejects a result carrying a loaded relationship",
      assertion:
        "assert {:error, %Error{code: :response_value_invalid}} = Resource.encode(loaded, contract, [])"
    },
    "scope-component-limit" => %{
      path: "lib/ash_onetime/scope.ex",
      original: "length(components) > @max_components ->",
      mutated: "length(components) > 999_999 ->",
      test: "test/ash_onetime/scope_test.exs",
      tag: "scope_component_limit_mutation",
      test_name: "rejects one component over the limit",
      assertion: "assert {:error, message} = Scope.normalize(over)"
    },
    "scope-uniqueness" => %{
      path: "lib/ash_onetime/scope.ex",
      original: "Enum.uniq(components) != components ->",
      mutated: "false ->",
      test: "test/ash_onetime/scope_test.exs",
      tag: "scope_uniqueness_mutation",
      test_name: "rejects duplicate components",
      # ExUnit renders the keyword-list scope in shorthand in the failed-assertion source.
      assertion: "Scope.normalize(static: \"x\", attribute: :a, static: \"x\")"
    },
    "ed25519-verify-honored" => %{
      path: "lib/ash_onetime/signer/ed25519.ex",
      original: "if :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519]) do",
      mutated: "if true do",
      test: "test/ash_onetime/signer/ed25519_test.exs",
      tag: "ed25519_wrong_key_mutation",
      test_name: "a valid signature is invalid under a different, equally valid public key",
      assertion: "Ed25519.verify(\"bound to key A\", signature, public(public_b))"
    },
    "canonical-decoder-order" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "is_nil(previous) or key_raw > previous ->",
      mutated: "is_nil(previous) or is_binary(key_raw) ->",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_decoder_identity_mutation",
      test_name: "decoder rejects trailing, duplicate, and noncanonical map bytes",
      assertion: "Decoder.decode(reversed)"
    },
    "token-from-body-bounds" => %{
      path: "lib/ash_onetime/token.ex",
      original: ":ok <- validate_identifier(body[\"key_id\"], :invalid_key_id, :key_id),",
      mutated: ":ok <- :ok,",
      test: "test/ash_onetime/token_test.exs",
      tag: "token_from_body_bounds_mutation",
      test_name: "verify re-validates the decoded body's key_id bound before the signature",
      assertion: "Token.verify(encoded, KeyResolver, verify_options())"
    },
    "secure-equal-truncate" => %{
      path: "lib/ash_onetime/signer/hmac.ex",
      original: "|> :binary.bin_to_list()",
      mutated: "|> :binary.bin_to_list() |> Enum.take(1)",
      test: "test/ash_onetime/signer/hmac_test.exs",
      tag: "secure_equal_full_length_mutation",
      test_name:
        "a tamper anywhere past the first byte fails closed (full-length constant-time compare)",
      assertion: "HMAC.verify(\"Hi There\", last, material)"
    },
    "secure-equal-length" => %{
      path: "lib/ash_onetime/signer/hmac.ex",
      original: "defp secure_equal(_left, _right), do: false",
      mutated: "defp secure_equal(_left, _right), do: true",
      test: "test/ash_onetime/signer/hmac_test.exs",
      tag: "secure_equal_length_mutation",
      test_name: "invalid trusted keys and signature sizes fail closed",
      assertion: "HMAC.verify(\"message\", <<0>>, same_service(@rfc_key))"
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
    "dsl-attribute-tenant-scope" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_tenant_scope(scope, protection, context),\n    do: verify_tenant_scope_details(scope, protection, context)",
      mutated: "  defp verify_tenant_scope(_scope, _protection, _context), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_attribute_tenant_scope_mutation",
      test_name: "attribute multitenancy requires the tenant discriminator in scope",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe:
        {"attribute_multitenant_unscoped.exs",
         "AshOnetime.CompileFixtures.AttributeMultitenantUnscoped"}
    },
    "dsl-attribute-tenant-scope-equality" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "not is_nil(tenant_attribute) and attribute == tenant_attribute",
      mutated: "not is_nil(tenant_attribute) and is_atom(attribute)",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_attribute_tenant_scope_equality_mutation",
      test_name: "attribute multitenancy rejects a non-tenant attribute in scope",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe:
        {"attribute_multitenant_wrong_attribute.exs",
         "AshOnetime.CompileFixtures.AttributeMultitenantWrongAttribute"}
    },
    "dsl-response-unknown-opt" => %{
      path: "lib/ash_onetime/resource.ex",
      original:
        "      fields: [\n        type: {:list, :atom},\n        default: [],\n        doc:\n          \"The resource attributes projected into the stored/replayed response payload. \" <>\n            \"Acts as the field allowlist; attributes not named here never enter the response.\"\n      ],",
      mutated:
        "      field: [\n        type: {:list, :atom},\n        default: [],\n        doc: \"mutant alias that accepts the typo the guard rejects.\"\n      ],\n      fields: [\n        type: {:list, :atom},\n        default: [],\n        doc:\n          \"The resource attributes projected into the stored/replayed response payload. \" <>\n            \"Acts as the field allowlist; attributes not named here never enter the response.\"\n      ],",
      test: "test/compile_fixtures_test.exs",
      tag: "response_unknown_opt_mutation",
      test_name: "response rejects unknown options (no silent drop)",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"response_unknown_opt.exs", "AshOnetime.CompileFixtures.ResponseUnknownOpt"}
    },
    "response-limits-unknown-key" => %{
      path: "lib/ash_onetime/response.ex",
      original:
        "    if typos == [],\n      do: {:ok, selected},\n      else: {:error, :unknown, Enum.map(typos, &elem(&1, 0))}",
      mutated: "    {:ok, selected}",
      test: "test/ash_onetime/codec/response_test.exs",
      tag: "response_limits_unknown_key_mutation",
      test_name: "response limits reject unknown option keys (no silent drop)",
      assertion: "{:error, %Error{code: :response_contract_invalid}}"
    },
    "structural-limits-map-take" => %{
      path: "lib/ash_onetime/codec.ex",
      original:
        "    Map.merge(known, Map.take(Map.get(contract, :limits, %{}), Map.keys(known)))",
      mutated: "    Map.merge(known, Map.get(contract, :limits, %{}))",
      test: "test/ash_onetime/codec/resource_test.exs",
      tag: "structural_limits_map_take_mutation",
      test_name: "structural_limits ignores non-response keys even on an un-normalized contract",
      assertion: "refute Map.has_key?(structural, :max_key_bytes)"
    },
    "unique-constraint" => %{
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original: "@collision_constraint \"UNIQUE (operation_hash, scope_hash, key_hash)\"",
      mutated: "@collision_constraint \"CHECK (true)\"",
      test: "test/system/contention_test.exs",
      tag: "unique_constraint_mutation",
      test_name: "a contended real action commits one append-only effect",
      assertion: "assert first_result.id == second_result.id"
    },
    "cleanup-boundary" => %{
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original: "@cleanup_comparator \">\"",
      mutated: "@cleanup_comparator \">=\"",
      test: "test/system/window_cleanup_test.exs",
      tag: "cleanup_strictness_mutation",
      test_name:
        "cleanup preserves the inclusive replay horizon then removes the first expired instant",
      assertion: "assert %{rows: [[false]]} ="
    },
    "reap-removes-abandoned" => %{
      path: "priv/templates/migrations/install.exs",
      original: "AND inserted_at < reap_before",
      mutated: "AND false",
      test: "test/ash_onetime/store/reap_test.exs",
      tag: "reap_removes_abandoned_mutation",
      test_name:
        "reaps a processing recovery point past the abandonment horizon and its retention",
      assertion: "assert {:ok, 1} = Store.reap(target, 100, @horizon)"
    },
    "reap-retention-guard" => %{
      path: "priv/templates/migrations/install.exs",
      original: "OR NOT \#{q(\"ash_onetime_cleanup_eligible\")}(OLD.retain_until) THEN",
      mutated: "OR false THEN",
      test: "test/ash_onetime/store/reap_test.exs",
      tag: "reap_retention_guard_mutation",
      test_name: "never reaps a processing claim still inside its retention horizon",
      assertion: "assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ="
    },
    "reap-floor-guard" => %{
      path: "priv/templates/migrations/install.exs",
      original:
        "OR OLD.inserted_at >= transaction_timestamp() - (\#{@abandonment_floor_seconds} * interval '1 second')",
      mutated: "OR false",
      test: "test/ash_onetime/store/reap_test.exs",
      tag: "reap_floor_guard_mutation",
      test_name: "never reaps a processing claim younger than the hard floor",
      assertion: "assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ="
    },
    "reap-skips-locked-recovery" => %{
      path: "priv/templates/migrations/install.exs",
      original: "ORDER BY inserted_at, operation_hash, id\n        FOR UPDATE SKIP LOCKED",
      mutated: "ORDER BY inserted_at, operation_hash, id\n        FOR UPDATE",
      test: "test/ash_onetime/store/reap_contention_test.exs",
      tag: "reap_skips_locked_recovery_mutation",
      test_name: "the reaper skips a recovery point locked by an in-flight finalization",
      assertion: "assert_receive {:reaper_done, ^reaper, {:ok, 0}}"
    },
    "payload-partition" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "Date.compare(database_date, &1.until_date) == :gt",
      mutated: "Date.compare(database_date, &1.until_date) in [:eq, :gt]",
      test: "test/mix/tasks/ash_onetime.prune_test.exs",
      tag: "payload_partition_mutation",
      test_name:
        "manual cleanup retains the exact database-date boundary and drops only older empty partitions",
      assertion: "payload_partitions: 1"
    },
    "payload-partition-lock" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "IN SHARE MODE",
      mutated: "IN ACCESS SHARE MODE",
      test: "test/mix/tasks/ash_onetime.prune_test.exs",
      tag: "payload_partition_lock_mutation",
      test_name: "cleanup locks an empty partition before deciding to drop it",
      assertion: "payload_partitions: 0"
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
    },
    "task5-replay-execution" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "when class in [:execute, :external_execute, :nonce, :untracked] ->",
      mutated: "when class in [:execute, :external_execute, :nonce, :untracked, :replay] ->",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_replay_execution_mutation",
      test_name: "generic original runs once and its typed stored result replays",
      assertion: "refute_receive {:generic_run, _arguments}"
    },
    "task5-corrupt-replay-execution" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "{:error, %Error{} = error} ->\n        emit_conflict(state, :malformed)\n        {:error, error}",
      mutated:
        "{:error, %Error{} = _error} ->\n        {:execute, %{state | class: :execute, claim: result.claim}}",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_corrupt_replay_mutation",
      test_name: "corrupt authoritative replay is terminal and never repairs by executing again",
      assertion: "assert_terminal_replay(prefix, input)"
    },
    "task5-completion" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "case AshOnetime.Admission.complete(state, persisted_result) do",
      mutated: "case {:ok, persisted_result} do",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_mutation",
      test_name: "completion failure rolls back a generic effect through the real wrapper",
      assertion: "assert {:error, _error} ="
    },
    "task5-crud-result-tuple" => %{
      path: "lib/ash_onetime/change.ex",
      original: "|> Ash.Changeset.set_result({:ok, decoded})",
      mutated: "|> Ash.Changeset.set_result(decoded)",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_crud_tuple_mutation",
      test_name:
        "CRUD execution, claim, response completion, and replay share one tenant transaction",
      assertion: "|> Ash.create()"
    },
    "task5-crud-completion" => %{
      path: "lib/ash_onetime/change.ex",
      original: "case AshOnetime.Admission.complete(state, result) do",
      mutated: "case {:ok, result} do",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_crud_tuple_mutation",
      test_name:
        "CRUD execution, claim, response completion, and replay share one tenant transaction",
      assertion: "assert {:ok, replayed} ="
    },
    "task5-atomic-error-form" => %{
      path: "lib/ash_onetime/change.ex",
      original: "do: {:not_atomic, \"keyed effects require transactional stream execution\"}",
      mutated: "do: {:error, \"keyed effects require transactional stream execution\"}",
      test: "test/ash_onetime/change_test.exs",
      tag: "task5_atomic_shape_mutation",
      test_name: "protected changes force transactional stream execution",
      assertion:
        "assert {:not_atomic, \"keyed effects require transactional stream execution\"} ="
    },
    "task5-bulk-fallback" => %{
      path: "lib/ash_onetime/change.ex",
      original: "Enum.map(changesets, &change(&1, opts, context))",
      mutated: "changesets",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_bulk_fallback_mutation",
      test_name: "protected bulk create falls back to transactional stream execution",
      assertion: "assert table_count(prefix, \"ash_onetime_idempotency_claims\") == 2"
    },
    "task5-state-request-sanitization" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "request: sanitize_request(state.request)",
      mutated: "request: state.request",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_state_confidentiality_mutation",
      test_name: "verified nonce admits one generic execution then rejects reuse",
      assertion: "refute state_bytes =~ \"nonce-proof\""
    },
    "task5-state-claim-sanitization" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "class: class, claim: sanitize_claim(result.claim)",
      mutated: "class: class, claim: result.claim",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_state_confidentiality_mutation",
      test_name: "verified nonce admits one generic execution then rejects reuse",
      # The unsanitized claim leaks its verifier_id ("action-verifier") into the serialized
      # admission state, so the state_bytes refute fires before the later verifier_id assertion.
      assertion: "refute state_bytes =~ \"action-verifier\""
    },
    "task5-completion-codec" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "true <- claim.response_codec == encoded.codec,",
      mutated: "true <- is_binary(claim.response_codec),",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-completion-payload" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "true <- payload == encoded.payload,\n         true <- fixed_digest_equal?(claim.response_digest, encoded.digest),\n         true <- fixed_digest_equal?(:crypto.hash(:sha256, payload), encoded.digest)",
      mutated:
        "true <- is_binary(payload),\n         true <- fixed_digest_equal?(claim.response_digest, encoded.digest),\n         true <- true",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-completion-digest" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "true <- fixed_digest_equal?(claim.response_digest, encoded.digest),",
      mutated: "true <- is_binary(claim.response_digest),",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-completion-partition" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "response_partition: %Date{},",
      mutated: "response_partition: _response_partition,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-completion-partition-clock" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":ok <- validate_claim_state(claim, :complete),",
      mutated:
        ":ok <- validate_claim_state(claim, :complete),\n         true <- claim.response_partition == Date.utc_today(),",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_partition_clock_mutation",
      test_name:
        "completion trusts the PostgreSQL transaction date across an application date boundary",
      assertion: "assert {:ok, :completed} ="
    },
    "task5-completion-state" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":ok <- validate_claim_state(claim, :complete),",
      mutated: ":ok <- :ok,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-completion-outer" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "defp validate_complete(\n         %Result{\n           status: :complete,\n           reason: nil,\n           admission_dispatch: :sent,\n           transaction: :open,",
      mutated:
        "defp validate_complete(\n         %Result{\n           status: :complete,\n           reason: _reason,\n           admission_dispatch: _dispatch,\n           transaction: _transaction,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-completion-transaction" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "defp transaction_preconditions(target) do\n    if target.repo_module.in_transaction?() do",
      mutated: "defp transaction_preconditions(target) do\n    if true do",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_completion_transaction_mutation",
      test_name:
        "completion outside the caller transaction fails before changing authoritative state",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-untracked-siblings" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "reason: :checkout_unavailable,\n           admission_dispatch: :not_started,\n           transaction: :not_applicable,",
      mutated:
        "reason: _reason,\n           admission_dispatch: _dispatch,\n           transaction: _transaction,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_untracked_siblings_mutation",
      test_name: "exact checkout failure executes untracked only for opted-in idempotency",
      assertion: "assert {:error, %AshOnetime.Error{code: code}} ="
    },
    "task5-admitted-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "true <- claim.id == request.id,",
      mutated: "true <- true,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-fingerprint-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "if :crypto.hash_equals(left, right), do: :match, else: :fingerprint_mismatch",
      mutated: "if is_binary(left), do: :match, else: :fingerprint_mismatch",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_fingerprint_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-operation-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":crypto.hash_equals(claim.operation_hash, request.operation_hash) and",
      mutated: "is_binary(claim.operation_hash) and",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-scope-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":crypto.hash_equals(claim.scope_hash, request.scope_hash) and",
      mutated: "is_binary(claim.scope_hash) and",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-key-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":crypto.hash_equals(claim.key_hash, request.key_hash)",
      mutated: "is_binary(claim.key_hash)",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "task5-marker-propagation" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "{:replay, _decoded, state} -> AshOnetime.Admission.put_replay(input, state)",
      mutated: "{:replay, _decoded, state} -> AshOnetime.Admission.put_state(input, state)",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_marker_propagation_mutation",
      test_name: "generic original runs once and its typed stored result replays",
      assertion: "assert_receive {:replay_marker, true}"
    },
    "task5-generic-preparation" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original:
        "Ash.ActionInput.before_action(\n      fn pending -> reserve(pending, protection, context) end,",
      mutated: "Ash.ActionInput.before_action(\n      fn pending -> pending end,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "task5_marker_propagation_mutation",
      test_name: "generic original runs once and its typed stored result replays",
      assertion: "assert {:ok, 42} ="
    },
    "task5-notifier-guard" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "if notifiers == [] do",
      mutated: "if is_list(notifiers) do",
      test: "test/compile_fixtures_test.exs",
      tag: "task5_notifier_guard_mutation",
      test_name: "protected CRUD actions reject notifier delivery at compile time",
      assertion: "assert status != 0, output"
    },
    "task5-around-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "effects: effects,\n           around_action: false,\n           marker: :consumed",
      mutated:
        "effects: effects,\n           around_action: _around_action,\n           marker: :consumed",
      test: "test/compile_fixtures_test.exs",
      tag: "task5_around_guard_mutation",
      test_name: "protected CRUD actions reject every additional around-action producer",
      assertion: "for case_name <- ["
    },
    "task5-nonce-around-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "effects: _effects,\n           around_action: false,\n           marker: _marker",
      mutated:
        "effects: _effects,\n           around_action: _around_action,\n           marker: _marker",
      test: "test/compile_fixtures_test.exs",
      tag: "task5_around_guard_mutation",
      test_name: "protected CRUD actions reject every additional around-action producer",
      assertion: "for case_name <- ["
    },
    "task5-pure-producer-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "%{notifications: false, effects: false, around_action: false, marker: :unused} =\n           capabilities",
      mutated:
        "%{notifications: _notifications, effects: false, around_action: false, marker: :unused} =\n           capabilities",
      test: "test/compile_fixtures_test.exs",
      tag: "task5_capability_guard_mutation",
      test_name: "lifecycle notification and effect capability declarations fail closed",
      assertion: "for case_name <- ["
    },
    "task5-marker-consumption-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "effects: effects,\n           around_action: false,\n           marker: :consumed",
      mutated: "effects: effects,\n           around_action: false,\n           marker: _marker",
      test: "test/compile_fixtures_test.exs",
      tag: "task5_capability_guard_mutation",
      test_name: "lifecycle notification and effect capability declarations fail closed",
      assertion: "for case_name <- ["
    },
    "task5-wrapper-protection" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "change: {AshOnetime.Change, [protection: protection]},",
      mutated: "change: {AshOnetime.Change, [protection: nil]},",
      test: "test/ash_onetime/resource/verifier_test.exs",
      tag: "task5_wrapper_protection_mutation",
      test_name: "AshOnetime.Test.Support.Resource",
      assertion: "protected action is missing exactly one runtime wrapper"
    },
    "task5-dynamic-repo" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "%Target{repo_module: repo, dynamic_repo: repo.get_dynamic_repo(), prefix: prefix}",
      mutated: "%Target{repo_module: repo, dynamic_repo: repo, prefix: prefix}",
      test: "test/ash_onetime/store/transaction_test.exs",
      tag: "task5_dynamic_repo_mutation",
      test_name: "two live dynamic repo instances preserve their transaction and quoted prefix",
      assertion: "assert_receive {:live_repo_claimed, ^task_a_pid, :admitted}"
    },
    "task5-prefix-routing" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "quote_identifier(prefix) <> \".\" <> quote_identifier(name)",
      mutated: "quote_identifier(name)",
      test: "test/ash_onetime/tenant_prefix_test.exs",
      tag: "task5_prefix_routing_mutation",
      test_name: "the same complete key is isolated across two tenant prefixes",
      assertion: "assert {:ok, first} = create_in(prefix, input)"
    },
    "task5-authorization-order" => %{
      path: "lib/ash_onetime/change.ex",
      original: "protection = Keyword.fetch!(opts, :protection)\n\n    changeset",
      mutated:
        "protection = Keyword.fetch!(opts, :protection)\n\n    changeset = reserve(changeset, protection, context)\n\n    changeset",
      test: "test/ash_onetime/authorization_order_test.exs",
      tag: "task5_authorization_order_mutation",
      test_name: "change registration performs no admission callback before Ash authorization",
      assertion: "changeset = Ash.Changeset.for_create(Resource, :charge, valid_input())"
    },
    "task5-ledger-tamper" => %{
      path: "test/ash_onetime/action_contention_test.exs",
      original: "RAISE EXCEPTION 'action effect ledger is append-only' USING ERRCODE = '23514';",
      mutated: "RETURN OLD;",
      test: "test/ash_onetime/action_contention_test.exs",
      tag: "task5_ledger_tamper_mutation",
      test_name:
        "two protected Ash actions serialize at the authoritative claim and append one effect",
      assertion: "assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ="
    },
    "external-recover" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original: "case module.recover(operation_key, subject, context) do",
      mutated: "case :unknown do",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "external_recover_mutation",
      test_name: "peer success followed by caller death recovers without another execute",
      assertion: "assert [[\"execute\", ^operation_key], [\"recover\", ^operation_key]] =",
      required_failures: [
        {"caller death before peer preserves one key and retry proves absence",
         "assert [[\"recover\", ^operation_key], [\"execute\", ^operation_key]] ="},
        {"peer success followed by caller death recovers without another execute",
         "assert [[\"execute\", ^operation_key], [\"recover\", ^operation_key]] ="},
        {"unknown execute is recovered once immediately",
         "assert [[\"execute\", operation_key], [\"recover\", operation_key]] ="}
      ],
      red_summary: "Result: 0/3 passed, 9 excluded",
      green_summary: "Result: 3 passed, 9 excluded"
    },
    "external-operation-key" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        "defp continue({:recover, state}, subject, protection, context, started) do\n    operation_key = state.claim.id",
      mutated:
        "defp continue({:recover, state}, subject, protection, context, started) do\n    operation_key = state.request.id",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "external_operation_key_mutation",
      test_name: "caller death before peer preserves one key and retry proves absence",
      assertion: "assert [[\"recover\", ^operation_key], [\"execute\", ^operation_key]] ="
    },
    "ambiguous-retry" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        ":unknown ->\n        ambiguous_recovery(state, started)\n    end\n  end\n\n  defp execute_then_settle",
      mutated:
        ":unknown ->\n        execute_then_settle(state, subject, protection, context, operation_key, started)\n    end\n  end\n\n  defp execute_then_settle",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "ambiguous_retry_mutation",
      test_name: "ambiguous recovery never executes or finalizes",
      assertion:
        "assert ExternalPeer.calls(context.prefix) == calls_before ++ [[\"recover\", operation_key]]"
    },
    "ambiguous-retry-settle" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        ":unknown ->\n        ambiguous_recovery(state, started)\n    end\n  end\n\n  # mutation sentinel: ambiguous-retry",
      mutated:
        ":unknown ->\n        execute_then_settle(state, subject, protection, operation_key, callback_context, started)\n    end\n  end\n\n  # mutation sentinel: ambiguous-retry",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "ambiguous_retry_mutation",
      test_name:
        "ambiguous outcome from an unknown execute and recover never executes or finalizes",
      assertion: "assert Exception.message(error) =~ \"external effect outcome is unknown\""
    },
    "completion-once" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      AND id = $7::uuid AND state = 'processing'\n",
      mutated: "      AND id = $7::uuid AND state = 'complete'\n",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "completion_once_mutation",
      test_name: "the completion state predicate is the effect-once backstop without a payload",
      assertion: "assert {:error, %Result{status: :failure, reason: :store_invariant}} ="
    },
    "completion-invariant-rollback" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "WHERE claim_id = $7::uuid\n      ) = 1\n",
      mutated: "WHERE claim_id = $7::uuid\n      ) >= 1\n",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_invariant_rollback_mutation",
      test_name:
        "a real completion invariant rolls back claim, payload, and effect through the Ash pipeline",
      # The mutation makes the poisoned completion succeed, so the `{:error, error} = Ash.create`
      # match is the assertion that goes RED; ExUnit prints its source, which carries this unique
      # input needle. (The follow-on :store_invariant code assertion never executes under RED.)
      assertion: "charge_input(account_id, 10, \"poisoned-completion\")"
    },
    "task5-reserved-input" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "with :ok <- reject_reserved(subject),",
      mutated: "with :ok <- :ok,",
      test: "test/ash_onetime/authorization_order_test.exs",
      tag: "task5_reserved_mutation",
      test_name: "reserved verification facts reject before callbacks and SQL",
      assertion: "assert {:error, %AshOnetime.Error{code: :reserved_verification_input}} ="
    },
    "task5-composite-clock" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "issued_at: latest.issued_at,",
      mutated: "issued_at: List.first(verified_facts).issued_at,",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "task5_composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert DateTime.compare(claim.issued_at, latest_issued_at) == :eq"
    },
    "task5-composite-expiry" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "expires_at: nil,",
      mutated: "expires_at: List.first(verified_facts).expires_at,",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "task5_composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert {:ok, %Result{status: :admitted, claim: claim}} ="
    },
    "task5-composite-cleanup" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "|> Enum.max(DateTime)",
      mutated: "|> Enum.min(DateTime)",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "task5_composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert DateTime.compare("
    },
    "task5-composite-verifier-order" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "verifier_ids = Enum.map(verified_facts, & &1.verifier_id)",
      mutated: "verifier_ids = [List.first(verified_facts).verifier_id]",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "task5_composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert claim.verifier_id == Base.url_encode64(verifier_digest, padding: false)"
    },
    "task5-composite-sibling-validation" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "Enum.all?(verified_facts, &valid_verified_fact?(&1, evaluated_at, max_age, skew))",
      mutated:
        "Enum.all?([List.last(verified_facts)], &valid_verified_fact?(&1, evaluated_at, max_age, skew))",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "task5_composite_sibling_mutation",
      test_name: "one invalid composite nonce sibling rejects the entire admission",
      assertion: "assert {:ok, %Result{status: :failure, reason: :invalid_nonce_window}} ="
    },
    "cache-admission" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "  defp decide(%Result{} = result, state, _protection, _started, _mode) do\n    emit_uncertainty(result, state)\n    {:error, store_error(result)}\n  end",
      mutated:
        "  defp decide(%Result{} = result, %{strategy: :idempotency} = state, protection, started, mode) do\n    if Application.get_env(:ash_onetime, :cache, AshOnetime.Cache.None) != AshOnetime.Cache.None do\n      emit_uncertainty(result, state)\n      {:execute_untracked, %{state | class: :untracked}}\n    else\n      decide(result, state, protection, started, mode, :cache_disabled)\n    end\n  end\n\n  defp decide(%Result{} = result, state, protection, started, mode),\n    do: decide(result, state, protection, started, mode, :cache_disabled)\n\n  defp decide(%Result{} = result, state, _protection, _started, _mode, :cache_disabled) do\n    emit_uncertainty(result, state)\n    {:error, store_error(result)}\n  end",
      test: "test/system/cache_degradation_test.exs",
      tag: "system_cache_admission_mutation",
      test_name: "cache presence cannot admit when authoritative PostgreSQL rejects",
      assertion: "assert {:error, _error} = run(prefix, \"cache-must-not-admit\", 99)"
    },
    "nonce-failure-direction" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "         %{strategy: :idempotency} = state,\n         %{on_definite_store_failure: :execute_untracked},\n         started,\n         :local_claim\n       ) do",
      mutated:
        "         %{strategy: _strategy} = state,\n         _protection,\n         started,\n         :local_claim\n       ) do",
      test: "test/system/failure_direction_test.exs",
      tag: "nonce_failure_direction_mutation",
      test_name:
        "nonce always fails closed while only a definite idempotency checkout can opt out",
      assertion: "assert {:error, %Error{code: :checkout_unavailable}} ="
    },
    "nonce-minted-composite" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "      length(protection.key) > 1 and Enum.any?(protection.key, &match?({:minted, _}, &1)) ->",
      mutated: "      false ->",
      test: "test/compile_fixtures_test.exs",
      tag: "nonce_minted_composite_mutation",
      test_name: "a fresh minted nonce source cannot join a verified key",
      assertion: "assert status != 0, output"
    },
    "signature-compare" => %{
      path: "lib/ash_onetime/signer/hmac.ex",
      original: "    |> Kernel.==(0)",
      mutated: "    |> Kernel.!=(0)",
      test: "test/system/package_consumer_test.exs",
      tag: "signature_compare_mutation",
      test_name: "meaningful signature-byte tampering fails closed",
      assertion: "assert {:error, %Error{code: :invalid_signature}} ="
    },
    "canonical-domain-tag" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  @integer_tag 0x02",
      mutated: "  @integer_tag 0x03",
      test: "test/system/package_consumer_test.exs",
      tag: "canonical_domain_tag_mutation",
      test_name: "canonical domains stay distinct and the package has no application callback",
      assertion: "assert {:ok, <<2, _::binary>>} = Canonical.encode(1)"
    },
    "action-replay" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "when class in [:execute, :external_execute, :nonce, :untracked] ->",
      mutated: "when class in [:execute, :external_execute, :nonce, :untracked, :replay] ->",
      test: "test/system/contention_test.exs",
      tag: "action_replay_mutation",
      test_name: "typed replay and action and scope namespaces remain independent",
      assertion: "refute_receive {:generic_run, _}"
    },
    "for-repo-prefix-bound" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "    unless is_nil(prefix) or valid_prefix?(prefix) do",
      mutated: "    unless is_nil(prefix) or is_binary(prefix) do",
      test: "test/ash_onetime/store/transaction_test.exs",
      tag: "for_repo_prefix_bound_mutation",
      test_name: "for_repo rejects a schema prefix beyond PostgreSQL's 63-byte identifier limit",
      assertion: "Postgres.for_repo(Repo, over_bound)"
    },
    "prefix-length-bound" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "  defp valid_prefix?(value), do: is_binary(value) and byte_size(value) in 1..63",
      mutated: "  defp valid_prefix?(value), do: is_binary(value) and byte_size(value) in 1..64",
      test: "test/ash_onetime/store/transaction_test.exs",
      tag: "prefix_length_bound_mutation",
      test_name:
        "target rejects a context tenant prefix beyond PostgreSQL's 63-byte identifier limit",
      assertion: "Postgres.target(AshOnetime.Test.TenantStoreResource, tenant: over_bound)"
    },
    "error-splode-membership" => %{
      path: "lib/ash_onetime/error.ex",
      original: "  use Splode.Error, class: :invalid, fields: [:code, :message, :details]",
      mutated:
        "  defexception code: nil, message: nil, details: %{}, class: :invalid, splode: nil, bread_crumbs: [], vars: [], path: [], stacktrace: nil",
      test: "test/ash_onetime/error_test.exs",
      tag: "error_splode_membership_mutation",
      test_name: "AshOnetime.Error is recognized as an Ash error",
      assertion: "assert Ash.Error.ash_error?(error) == true"
    },
    "replay-metadata" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "        Ash.Resource.put_metadata(record, :ash_onetime, %{replayed: class == :replay})",
      mutated: "        record",
      test: "test/ash_onetime/replay_metadata_test.exs",
      tag: "replay_metadata_mutation",
      test_name: "fresh create stamps replayed: false; retry stamps replayed: true",
      assertion: "assert AshOnetime.replayed?(fresh) == false",
      required_failures: [
        {"fresh create stamps replayed: false; retry stamps replayed: true",
         "assert AshOnetime.replayed?(fresh) == false"}
      ]
    },
    "untracked-transparency" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "  def stamp_replay(%State{class: :untracked}, result), do: result",
      mutated:
        "  def stamp_replay(%State{class: :untracked}, result), do: Ash.Resource.put_metadata(result, :ash_onetime, %{replayed: false})",
      test: "test/ash_onetime/replay_metadata_test.exs",
      tag: "untracked_transparency_mutation",
      test_name: "an untracked execution carries no :ash_onetime metadata (replayed? nil)",
      assertion: "assert stamped.__metadata__ == %{}"
    }
  }

  @forbidden_telemetry [
    scope: "raw-scope",
    scope_hash: <<0::256>>,
    key: "raw-key",
    key_hash: <<0::256>>,
    token: "token",
    fingerprint: <<0::256>>,
    response: "response",
    payload: "payload",
    signature: "signature",
    resolver_id: "resolver",
    verifier_id: "verifier",
    secret: "secret",
    store_result: %{status: :failure},
    exception: %RuntimeError{message: "sensitive"}
  ]

  @telemetry_builder """
  metadata = %{
          strategy: strategy,
          resource: resource,
          action: action,
          result_class: result_class
        }
  """

  @mutations Enum.reduce(@forbidden_telemetry, @mutations, fn {field, value}, mutations ->
               mutated =
                 "metadata = Map.put(%{\n" <>
                   "        strategy: strategy,\n" <>
                   "        resource: resource,\n" <>
                   "        action: action,\n" <>
                   "        result_class: result_class\n" <>
                   "      }, #{inspect(field)}, #{inspect(value, limit: :infinity)})\n"

               Map.put(mutations, "task5-telemetry-#{field}", %{
                 path: "lib/ash_onetime/telemetry.ex",
                 original: @telemetry_builder,
                 mutated: mutated,
                 test: "test/ash_onetime/action_transaction_test.exs",
                 tag: "task5_actual_telemetry_mutation",
                 test_name: "actual admission paths emit every closed telemetry family",
                 assertion:
                   "assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]"
               })
             end)

  # `all` is computed from @mutations rather than hand-listed, which is what STRUCTURALLY prevents
  # the orphan class (a newly added mutation is in `all` by construction — CONTRIBUTING and the CI
  # release-checks job both run `-- all`). The self-test below is a REGRESSION GUARD, not present
  # coverage: while `all` is `Map.keys(@mutations)` it can never fire, but it trips the moment a
  # future change reverts `all` to a hand-list that drops a registered mutation — the exact drift
  # that once orphaned the ARCH mutations. The named subsets below stay for fast, focused local runs.
  @groups %{
    "all" => Map.keys(@mutations),
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
      "dsl-validations",
      "dsl-attribute-tenant-scope"
    ],
    "operation-hash" => [
      "operation-hash-select",
      "operation-hash-completion",
      "operation-hash-cleanup"
    ],
    "reap" => [
      "reap-removes-abandoned",
      "reap-retention-guard",
      "reap-floor-guard",
      "reap-skips-locked-recovery"
    ],
    "task5" =>
      [
        "task5-replay-execution",
        "task5-corrupt-replay-execution",
        "task5-completion",
        "task5-crud-result-tuple",
        "task5-crud-completion",
        "task5-atomic-error-form",
        "task5-bulk-fallback",
        "task5-state-request-sanitization",
        "task5-state-claim-sanitization",
        "task5-completion-codec",
        "task5-completion-payload",
        "task5-completion-digest",
        "task5-completion-partition",
        "task5-completion-partition-clock",
        "task5-completion-state",
        "task5-completion-outer",
        "task5-completion-transaction",
        "task5-untracked-siblings",
        "task5-admitted-identity",
        "task5-fingerprint-identity",
        "task5-operation-identity",
        "task5-scope-identity",
        "task5-key-identity",
        "task5-marker-propagation",
        "task5-generic-preparation",
        "task5-notifier-guard",
        "task5-around-capability",
        "task5-nonce-around-capability",
        "task5-pure-producer-capability",
        "task5-marker-consumption-capability",
        "task5-wrapper-protection",
        "task5-dynamic-repo",
        "task5-prefix-routing",
        "task5-authorization-order",
        "task5-ledger-tamper",
        "task5-reserved-input",
        "task5-composite-clock",
        "task5-composite-expiry",
        "task5-composite-cleanup",
        "task5-composite-verifier-order",
        "task5-composite-sibling-validation"
      ] ++ Enum.map(@forbidden_telemetry, fn {field, _value} -> "task5-telemetry-#{field}" end)
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

    # Regression guard (see @groups): tautological while `all` is Map.keys(@mutations), but it
    # trips if a future change reverts `all` to a hand-list that drops a registered mutation —
    # the drift that once orphaned three ARCH mutations from every runnable command.
    grouped = @groups |> Map.values() |> List.flatten() |> MapSet.new()
    orphaned = @registered |> MapSet.difference(grouped) |> MapSet.to_list() |> Enum.sort()

    case orphaned do
      [] ->
        IO.puts("mutation checker self-test: every registered mutation is in a runnable group")

      names ->
        IO.puts(
          :stderr,
          "mutation checker self-test failed: orphaned mutations: #{Enum.join(names, ", ")}"
        )

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

    required_failures =
      Map.get(mutation, :required_failures, [{mutation.test_name, mutation.assertion}])

    for {test_name, assertion} <- required_failures do
      IO.puts("mutation #{name}: expected failing test: #{test_name}")
      IO.puts("mutation #{name}: expected failing assertion: #{assertion}")
    end

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

    unless Enum.all?(required_failures, fn {test_name, assertion} ->
             String.contains?(red_output, test_name) and String.contains?(red_output, assertion)
           end) do
      raise "mutation #{name} failed without every required named assertion"
    end

    assert_summary!(name, :mutant, red_output, Map.get(mutation, :red_summary))

    unless File.read!(mutation.path) == original_source do
      raise "mutation #{name} did not restore exact source bytes"
    end

    {restored_output, restored_status} = run_test(mutation)
    IO.puts("mutation #{name}: restored command output follows")
    IO.puts(restored_output)

    if restored_status != 0 do
      raise "mutation #{name} did not return green after restoration"
    end

    assert_summary!(name, :restored, restored_output, Map.get(mutation, :green_summary))

    IO.puts("mutation #{name}: RED confirmed; exact source bytes restored; tagged test GREEN")
  end

  defp assert_single_site!(source, needle, path) do
    case :binary.matches(source, needle) do
      [_single] -> :ok
      matches -> raise "mutation site count for #{path} was #{length(matches)}, expected 1"
    end
  end

  defp assert_summary!(_name, _phase, _output, nil), do: :ok

  defp assert_summary!(name, phase, output, expected) do
    unless String.contains?(output, expected) do
      raise "mutation #{name} #{phase} output omitted required summary #{inspect(expected)}"
    end
  end

  defp probe_fixture!(_name, %{probe: nil}), do: :ok

  defp probe_fixture!(name, %{probe: {fixture, expected}}) do
    fixture = Path.expand(Path.join("test/compile_fixtures", fixture))
    env = mutation_environment()

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
    env = mutation_environment()

    System.cmd(
      "mix",
      ["test", "--force", mutation.test, "--only", mutation.tag, "--seed", "0"],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp mutation_environment do
    [
      {"MIX_ENV", "test"},
      {"DATABASE_URL", @database_url}
    ]
    |> maybe_put_build_path(System.get_env("MIX_BUILD_PATH"))
  end

  defp maybe_put_build_path(environment, nil), do: environment

  defp maybe_put_build_path(environment, build_path),
    do: [{"MIX_BUILD_PATH", build_path} | environment]

  defp validate([]), do: {:error, ["no mutation checks requested"]}

  defp validate(names) do
    unknown = Enum.reject(names, &MapSet.member?(@registered, &1))
    if unknown == [], do: :ok, else: {:error, unknown}
  end
end

AshOnetime.MutationCheck.main(System.argv())
