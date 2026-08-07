# Errors and HTTP mapping

`AshOnetime.Error` is a [Splode](https://hexdocs.pm/splode) error of class `:invalid`, so
Ash recognizes it and preserves it through the action pipeline. When a protected action
fails, the typed `:code` reaches the caller — either as the leaf error directly (single
error) or inside `Ash.Error.Invalid{errors: [...]}` (multiple errors) — instead of being
wrapped as an unknown error.

## Reading the code

`AshOnetime.Error.code/1` recovers the typed code from whatever Ash hands the caller,
without pattern-matching the wrapper shape:

```elixir
case Ash.create(changeset) do
  {:ok, record} -> record
  {:error, error} ->
    case AshOnetime.Error.code(error) do
      :nonce_already_used -> {:conflict, "nonce was already used"}
      :key_reused_with_different_request -> {:conflict, "key reused with a different request"}
      :request_in_progress -> {:conflict, "request is already processing"}  # 425 Too Early also fits
      :verification_failed -> {:unauthorized, "verification failed"}
      :verification_timeout -> {:service_unavailable, "verification timed out"}
      nil -> {:internal_server_error, "unexpected error"}  # not an ash_onetime error
    end
end
```

`code/1` returns `nil` for any value that is not an `AshOnetime.Error` and contains no
`AshOnetime.Error` leaf — so "ash_onetime rejected this with a known code" is cleanly
distinguishable from "some other error occurred."

## Class and HTTP

All `AshOnetime.Error` codes are class `:invalid`. AshJsonApi and AshGraphql auto-map class
`:invalid` to the 4xx family. The code→HTTP table below names the recommended status per
code; **two codes are server-side faults, not client input**, and override the class default
to 5xx — a consumer mapping class→HTTP must special-case these two.

### Client-input / operational codes (4xx)

| Code | HTTP | Meaning |
|---|---|---|
| `:nonce_already_used` | 409 | A one-time nonce was already spent. |
| `:key_reused_with_different_request` | 409/422 | An idempotency key was reused with a different request fingerprint. |
| `:request_in_progress` | 409 / 425 | A `processing` claim is still in flight for this key. |
| `:verification_failed` | 401 | A trusted verifier rejected the token. |
| `:verification_timeout` | 503 | A trusted verifier timed out (retryable). |
| `:fingerprint_too_large` | 422 | The request fingerprint exceeded its byte limit. |
| `:fingerprint_unavailable` | 422 | The request fingerprint could not be computed. |
| `:key_too_large` | 422 | A key component exceeded its byte limit. |
| `:key_unavailable` | 422 | A key component could not be resolved. |
| `:key_resolution_failed` | 422 | The key resolver callback failed. |
| `:key_not_found` | 404 | A referenced key was not found. |
| `:scope_unavailable` | 422 | A scope component could not be resolved. |
| `:invalid_key` | 422 | A key is structurally invalid. |
| `:invalid_key_role` | 422 | A key source role is unrecognized. |
| `:invalid_window` | 422 | A nonce window is malformed. |
| `:invalid_expires_at` | 422 | A verified expiry is malformed. |
| `:invalid_token` | 422 | A token is structurally invalid. |
| `:malformed_token` | 422 | A token envelope could not be parsed. |
| `:invalid_encoding` | 422 | A canonical encoding is invalid. |
| `:noncanonical_encoding` | 422 | A canonical encoding is non-canonical. |
| `:noncanonical_envelope` | 422 | A token envelope is non-canonical. |
| `:invalid_signature` | 422 | A token signature is invalid. |
| `:signing_failed` | 422 | A token could not be signed. |
| `:invalid_message` | 422 | A signer message is invalid. |
| `:algorithm_mismatch` | 422 | A token algorithm does not match. |
| `:unsupported_algorithm` | 422 | A token algorithm is not supported. |
| `:namespace_mismatch` | 422 | A token namespace does not match. |
| `:token_too_large` | 422 | A token exceeded its byte limit. |
| `:duplicate_field` | 422 | A canonical map carried a duplicate field. |
| `:duplicate_map_key` | 422 | A canonical map carried a duplicate key. |
| `:unsupported_term` | 422 | A canonical term is unsupported. |
| `:limit_exceeded` | 422 | A configured limit was exceeded. |
| `:missing_option` | 422 | A required DSL option is missing. |
| `:invalid_option` | 422 | A DSL option is invalid. |
| `:invalid_options` | 422 | DSL options are invalid. |
| `:reserved_verification_input` | 422 | Reserved verification input was supplied. |
| `:response_rejected` | 422 | The response classifier rejected the result. |
| `:response_rollback` | 422 | The response classifier requested a rollback. |
| `:response_fields_invalid` | 422 | The response field allowlist is invalid. |
| `:response_value_invalid` | 422 | The response value is invalid. |
| `:response_codec_mismatch` | 422 | The persisted response codec does not match. |
| `:response_contract_mismatch` | 422 | The persisted response contract does not match. |
| `:external_effect_unavailable` | 422 | An external effect is unavailable. |
| `:external_recovery_unavailable` | 422 | External recovery is unavailable. |

### Server-fault codes (5xx — override the class default)

These are NOT client input. A consumer mapping class→HTTP to a blanket 4xx would
mis-categorize them; the per-code HTTP below overrides the `:invalid` class.

| Code | HTTP | Meaning |
|---|---|---|
| `:store_invariant` | **500** | The authoritative store returned a result that violated an internal invariant (integrity fault, not client input). |
| `:outcome_unknown` | **503** | External recovery was ambiguous; the effect's outcome could not be determined (retryable). |
| `:response_payload_invalid` | **500** | The persisted response payload is invalid. |
| `:response_persisted_state_invalid` | **500** | The persisted response state is invalid. |
| `:response_digest_mismatch` | **500** | The persisted response digest does not match the payload. |
| `:response_classifier_failed` | **500** | The response classifier callback raised. |
| `:response_classifier_invalid` | **500** | The response classifier returned an invalid disposition. |
| `:response_codec_failed` | **500** | The response codec raised. |
| `:response_codec_invalid` | **500** | The response codec output is invalid. |
| `:response_contract_invalid` | **500** | The response contract is invalid. |
| `:response_completion_failed` | **500** | Response completion failed. |
| `:admission_request_invalid` | **500** | The admission request is internally invalid. |
| `:admission_unavailable` | **503** | Admission is unavailable (fail-closed; retryable). |
| `:telemetry_invalid` | **500** | A telemetry event was invalid (internal). |

## No secrets in `details`

The `details` map carries non-secret context only. As of this release, no internal call
site populates `details` with key material, tokens, payloads, or signatures — the field is
empty at every call site. Because the error now renders through `Ash.error_descriptions`,
this matters: nothing classified reaches logs, API error renderers, or HTTP bodies via the
error channel. (Audited; re-audit any future call site that adds `details`.)
