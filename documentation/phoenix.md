# Phoenix integration

`ash_onetime` does not depend on Phoenix. The integration surface is a [Plug](https://hexdocs.pm/plug)
module (`AshOnetime.Plug`) that copies request headers into the connection, the
[`AshOnetime.replayed?/1`](`AshOnetime.replayed?/1`) signal, and the error-code-to-HTTP-status
table in [Errors and HTTP mapping](errors.md). This guide shows an integration pattern to adapt
inside a Phoenix application. Its resource names, actions, response fields, and routes are host
application placeholders; verify the adapted controllers in that application's real Phoenix
request path.

## Wire the Plug

`AshOnetime.Plug` copies configured request headers into `conn.private.ash_onetime.untrusted`
as a map of `{context_name => binary}`. Values are raw and untrusted — verification happens only
inside the protected action. Add it to an API pipeline in your router:

```elixir
# lib/my_app_web/router.ex
pipeline :api do
  plug :accepts, ["json"]
  plug AshOnetime.Plug, headers: [idempotency_key: "idempotency-key"]
end

scope "/api", MyAppWeb do
  pipe_through :api
  post "/charges", ChargeController, :create
end
```

The header name is the wire name (`"idempotency-key"`); the context key (`:idempotency_key`)
matches the action argument. The Plug validates header syntax, rejects multi-valued or
oversized values, and raises `Plug.BadRequestError` on a violation.

## Share one sanitized error mapper

Ash may return an `AshOnetime.Error` leaf directly or inside an Ash class wrapper. Controllers
should recover the typed code with `AshOnetime.Error.code/1`, then pass only that code to one
shared mapper. The mapper below lists every client error explicitly, lists every retryable `503`
code explicitly, and fails unknown or server-fault codes closed to `500`.

Its public response contains only a recognized code string. It never serializes the exception,
calls the internal error-message helper on a wrapper, or exposes `details` and provider-supplied
reasons.

<!-- onetime-errors-helper:start -->
```elixir
defmodule MyAppWeb.OnetimeErrors do
  @moduledoc false

  @client_statuses %{
    nonce_already_used: :conflict,
    key_reused_with_different_request: :conflict,
    request_in_progress: :conflict,
    verification_failed: :unauthorized,
    fingerprint_too_large: :unprocessable_entity,
    fingerprint_unavailable: :unprocessable_entity,
    key_too_large: :unprocessable_entity,
    key_unavailable: :unprocessable_entity,
    key_resolution_failed: :unprocessable_entity,
    key_not_found: :not_found,
    scope_unavailable: :unprocessable_entity,
    invalid_key: :unprocessable_entity,
    invalid_key_role: :unprocessable_entity,
    invalid_window: :unprocessable_entity,
    invalid_nonce_window: :unprocessable_entity,
    invalid_expires_at: :unprocessable_entity,
    invalid_token: :unprocessable_entity,
    malformed_token: :unprocessable_entity,
    invalid_key_id: :unprocessable_entity,
    invalid_namespace: :unprocessable_entity,
    invalid_issued_at: :unprocessable_entity,
    invalid_trust_boundary: :unprocessable_entity,
    invalid_encoding: :unprocessable_entity,
    noncanonical_encoding: :unprocessable_entity,
    noncanonical_envelope: :unprocessable_entity,
    invalid_signature: :unprocessable_entity,
    signing_failed: :unprocessable_entity,
    invalid_message: :unprocessable_entity,
    algorithm_mismatch: :unprocessable_entity,
    unsupported_algorithm: :unprocessable_entity,
    namespace_mismatch: :unprocessable_entity,
    token_too_large: :unprocessable_entity,
    duplicate_field: :unprocessable_entity,
    duplicate_map_key: :unprocessable_entity,
    unsupported_term: :unprocessable_entity,
    limit_exceeded: :unprocessable_entity,
    missing_option: :unprocessable_entity,
    invalid_option: :unprocessable_entity,
    invalid_options: :unprocessable_entity,
    reserved_verification_input: :unprocessable_entity,
    response_rejected: :unprocessable_entity,
    response_rollback: :unprocessable_entity,
    response_fields_invalid: :unprocessable_entity,
    response_value_invalid: :unprocessable_entity,
    response_codec_mismatch: :unprocessable_entity,
    response_contract_mismatch: :unprocessable_entity,
    external_effect_unavailable: :unprocessable_entity,
    external_recovery_unavailable: :unprocessable_entity
  }

  @retryable_codes [
    :verification_timeout,
    :outcome_unknown,
    :admission_unavailable,
    :checkout_unavailable,
    :disconnected,
    :worker_timeout,
    :lock_timeout,
    :dispatched_unknown,
    :store_failure
  ]

  @server_codes [
    :store_invariant,
    :invalid_evaluated_at,
    :response_payload_invalid,
    :response_persisted_state_invalid,
    :response_digest_mismatch,
    :response_classifier_failed,
    :response_classifier_invalid,
    :response_codec_failed,
    :response_codec_invalid,
    :response_contract_invalid,
    :response_completion_failed,
    :admission_request_invalid,
    :telemetry_invalid,
    :missing_prefix,
    :not_in_transaction,
    :unsupported_isolation,
    :corrupt_payload,
    :invalid_request
  ]

  @known_codes Map.keys(@client_statuses) ++ @retryable_codes ++ @server_codes

  def status(code) do
    case Map.fetch(@client_statuses, code) do
      {:ok, status} -> status
      :error when code in @retryable_codes -> :service_unavailable
      :error -> :internal_server_error
    end
  end

  def public_code(code) when code in @known_codes, do: Atom.to_string(code)
  def public_code(_unknown), do: "internal_error"
end
```
<!-- onetime-errors-helper:end -->

## Idempotency controller (create action)

A create action protected with `:idempotency` strategy:

```elixir
defmodule MyAppWeb.ChargeController do
  use MyAppWeb, :controller
  alias MyApp.Charge
  alias AshOnetime
  alias MyAppWeb.OnetimeErrors

  def create(conn, _params) do
    # Read the untrusted header the Plug stashed.
    idempotency_key = conn.private.ash_onetime.untrusted[:idempotency_key]

    changeset =
      Charge
      |> Ash.Changeset.for_create(:charge, %{amount: conn.body_params["amount"]})
      |> Ash.Changeset.set_argument(:idempotency_key, idempotency_key)

    case Ash.create(changeset) do
      {:ok, charge} ->
        # replayed? is tri-state: true (replay) / false (fresh) / nil (untracked)
        conn
        |> maybe_put_replayed_header(AshOnetime.replayed?(charge))
        |> put_status(if AshOnetime.replayed?(charge) == true, do: :ok, else: :created)
        |> json(%{data: %{id: charge.id, amount: charge.amount}})

      {:error, error} ->
        render_error(conn, error)
    end
  end

  defp maybe_put_replayed_header(conn, true),
    do: put_resp_header(conn, "idempotent-replayed", "true")

  defp maybe_put_replayed_header(conn, _), do: conn

  defp render_error(conn, error) do
    code = AshOnetime.Error.code(error)

    conn
    |> put_status(OnetimeErrors.status(code))
    |> json(%{errors: %{code: OnetimeErrors.public_code(code)}})
  end
end
```

### The replay signal

| `AshOnetime.replayed?(record)` | HTTP status | `Idempotent-Replayed` header |
|---|---|---|
| `true` (tracked replay) | `200 OK` | `Idempotent-Replayed: true` |
| `false` (tracked fresh) | `201 Created` | *(not set)* |
| `nil` (untracked / primitive return) | `201 Created` | *(not set)* |

The `nil` branch is load-bearing: an untracked execution must be observationally indistinguishable
from a fresh one (ADR-0001's untracked-transparency goal). Map it to `201`, never `200`.

## Nonce controller (single-use redemption)

A one-time nonce action has `replayed?/1 == nil` always (nonces don't store a replayable
response — the second call is rejected, not replayed). The controller shape is simpler:

```elixir
defmodule MyAppWeb.RedemptionController do
  use MyAppWeb, :controller
  alias MyApp.Redemption
  alias AshOnetime
  alias MyAppWeb.OnetimeErrors

  def redeem(conn, _params) do
    proof = conn.private.ash_onetime.untrusted[:proof]

    changeset =
      Redemption
      |> Ash.Changeset.for_update(:redeem, %{})
      |> Ash.Changeset.set_argument(:proof, proof)

    case Ash.update(changeset) do
      {:ok, redemption} ->
        conn
        |> put_status(:ok)
        |> json(%{data: %{id: redemption.id, status: redemption.status}})

      {:error, error} ->
        code = AshOnetime.Error.code(error)

        conn
        |> put_status(OnetimeErrors.status(code))
        |> json(%{errors: %{code: OnetimeErrors.public_code(code)}})
    end
  end
end
```

Wire the Plug with `proof: "x-onetime-proof"` in the pipeline so the proof header flows into
the `:proof` argument.

## Notes

- The Plug's `conn.private.ash_onetime.untrusted` shape is `%{atom => binary}` — every value is
  a raw string. The protected action validates it; the controller must not treat it as trusted.
- The shared error mapper covers every code in the full table, including the 5xx store-fault
  codes that override Ash's class-based mapping. Keep the mapper synchronized with
  [Errors and HTTP mapping](errors.md).
- `AshOnetime.Error.code/1` accepts either a leaf or an Ash class wrapper. Build the public JSON
  body from its recognized code; keep the exception, message, `details`, and provider reasons in
  trusted server-side handling.
