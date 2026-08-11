# Phoenix integration

`ash_onetime` does not depend on Phoenix. The integration surface is a [Plug](https://hexdocs.pm/plug)
module (`AshOnetime.Plug`) that copies request headers into the connection, the
[`AshOnetime.replayed?/1`](`AshOnetime.replayed?/1`) signal, and the error-code-to-HTTP-status
table in [Errors and HTTP mapping](errors.md). This guide binds them into a runnable Phoenix
controller pattern so a consumer does not hand-roll the wiring.

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

## Idempotency controller (create action)

A create action protected with `:idempotency` strategy:

```elixir
defmodule MyAppWeb.ChargeController do
  use MyAppWeb, :controller
  alias MyApp.Charge
  alias AshOnetime

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

  # Map ash_onetime error codes to HTTP statuses.
  # See documentation/errors.md for the full table.
  defp render_error(conn, error) do
    status =
      case AshOnetime.Error.code(error) do
        :nonce_already_used -> :conflict
        :key_reused_with_different_request -> :conflict
        :request_in_progress -> :too_many_requests
        :verification_failed -> :unauthorized
        :verification_timeout -> :service_unavailable
        # All admission-availability / store-fault codes are 503
        code when code in [:admission_unavailable, :checkout_unavailable, :disconnected] ->
          :service_unavailable
        # Invalid-input family (validation, bounds, reserved) → 422
        _other -> :unprocessable_entity
      end

    conn
    |> put_status(status)
    |> json(%{errors: %{detail: AshOnetime.Error.message(error)}})
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
        case AshOnetime.Error.code(error) do
          :nonce_already_used ->
            conn |> put_status(:conflict) |> json(%{errors: %{detail: "nonce was already used"}})

          _other ->
            conn |> put_status(:internal_server_error) |> json(%{errors: %{detail: "unexpected error"}})
        end
    end
  end
end
```

Wire the Plug with `proof: "x-onetime-proof"` in the pipeline so the proof header flows into
the `:proof` argument.

## Notes

- The Plug's `conn.private.ash_onetime.untrusted` shape is `%{atom => binary}` — every value is
  a raw string. The protected action validates it; the controller must not treat it as trusted.
- The error-code → status mapping above covers the common codes. The full table (including the
  5xx store-fault codes that override Ash's class-based mapping) is in
  [Errors and HTTP mapping](errors.md).
- `AshOnetime.Error.code/1` returns the atom code for a given error; use it to build structured
  JSON error bodies. The error's `message/1` callback returns a human-readable string.
