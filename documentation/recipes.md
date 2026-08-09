# Recipes

Three end-to-end patterns — payment idempotency, webhook deduplication, and redemption-link
single-use — showing the resource DSL, a response codec, a classifier, and the call-site
result handling together. The codec and classifier shapes here match the `AshOnetime.Codec`
behaviour and the `classify/2` contract on `AshOnetime.ResponseClassifier`; copy them and
adapt the encode/decode/classify logic to your domain.

> Runnable shapes, not a runnable app. The modules compile against the published codec and
> classifier contracts; wire them into your own Ash domain and actions.

## Response codec and classifier contracts

Every idempotent action declares a `response` codec and a classifier. The codec serializes
the Ash return value into a self-describing `(tag, payload)` pair; the classifier decides
whether a given value is stored, rejected, or rolled back at the persistence boundary.

```elixir
# A codec implements the AshOnetime.Codec behaviour.
#   format_tag/0          -> a stable tag, 1..81 bytes, [A-Za-z0-9._-]+
#   encode(value, contract, opts)   -> {:ok, tag, payload} | {:error, AshOnetime.Error.t()}
#   decode(tag, payload, contract, opts) -> {:ok, value} | {:error, AshOnetime.Error.t()}
#
# A classifier is any module exporting classify/2; the contract (defined as a callback on
# AshOnetime.ResponseClassifier) is:
#   classify(value, context) -> {:store | :reject | :rollback, value}
defmodule MyApp.ChargeCodec do
  @behaviour AshOnetime.Codec

  @impl true
  def format_tag, do: "charge-v1"

  @impl true
  def encode(%{id: id, status: status}, _contract, _opts) do
    {:ok, format_tag(), "#{id}:#{status}"}
  end

  def encode(_value, _contract, _opts),
    do: {:error, AshOnetime.Error.new(:response_codec_invalid, "charge codec encode failed")}

  @impl true
  def decode("charge-v1", payload, _contract, _opts) do
    [id, status] = String.split(payload, ":", parts: 2)
    {:ok, %{id: id, status: status}}
  end

  def decode(_tag, _payload, _contract, _opts),
    do: {:error, AshOnetime.Error.new(:response_codec_invalid, "charge codec decode failed")}
end

defmodule MyApp.ChargeClassifier do
  # Only persist settled charges. A pending charge (e.g. asynchronous authorization) should
  # not be replayed as if it were final, so reject it; the action can run again.
  def classify(%{status: status} = value, _context) when status in ["captured", "settled"],
    do: {:store, value}

  def classify(_value, _context), do: {:reject, nil}
end
```

The `context` passed to `classify/2` is a map describing the call; classify on the value
alone unless your domain needs the context to decide. A classifier that raises, throws, or
returns an outcome outside `{:store | :reject | :rollback, _}` fails as
`:response_classifier_failed` / `:response_classifier_invalid` and never persists a value.

## Recipe 1 — Payment idempotency

A `charge` action that must execute once per client idempotency key and replay the stored
result on retry. Scope binds the account so one tenant cannot block or replay another; the
fingerprint binds `amount` so a retry with a *different* amount is a terminal conflict, not
a replay.

```elixir
defmodule MyApp.Charge do
  use Ash.Resource,
    domain: MyApp.Billing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false, public?: true
    attribute :amount, :integer, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, public?: true
  end

  actions do
    create :charge do
      accept [:account_id, :amount]
      change set_attribute(:status, "captured")
      # accept an Idempotency-Key header / argument supplied by the client
      argument :idempotency_key, :string, allow_nil?: false
    end
  end

  onetime do
    protect :charge do
      strategy :idempotency
      scope [{:attribute, :account_id}, {:static, "charge"}]
      key {:client, :idempotency_key}
      fingerprint attributes: [:amount, :account_id]
      response MyApp.ChargeCodec,
        fields: [:id, :status],
        classify: MyApp.ChargeClassifier
      retention {24, :hour}
    end
  end
end
```

At the call boundary:

```elixir
alias MyApp.Charge

# The client's Idempotency-Key is passed as an action argument.
changeset =
  Ash.Changeset.for_create(Charge, :charge, %{
    account_id: account_id,
    amount: 500,
    idempotency_key: conn |> get_req_header("idempotency-key") |> hd()
  })

case Ash.create(changeset) do
  {:ok, charge} ->
    # 201 the first time (replayed? == false); 200 + Idempotent-Replayed on a safe retry.
    status = if AshOnetime.replayed?(charge), do: 200, else: 201
    {:ok, %{status: status, charge: charge}}

  {:error, error} ->
    case AshOnetime.Error.code(error) do
      # The same key was retried with a different amount — terminal, never re-runs.
      :key_reused_with_different_request -> {:conflict, "idempotency key reused with a different payload"}
      # A concurrent request for the same key is mid-flight.
      :request_in_progress -> {:conflict, "a request for this key is already processing"}
      nil -> {:internal_server_error, "unexpected error"}
    end
end
```

## Recipe 2 — Webhook deduplication

A webhook receiver that must process each `(provider, event_id)` exactly once. Idempotency
keys on a client header fit this naturally: the provider's event id becomes the
idempotency key, and the scope binds the provider so one provider's retries cannot collide
with another's.

```elixir
defmodule MyApp.WebhookEvent do
  use Ash.Resource,
    domain: MyApp.Integrations,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  attributes do
    uuid_primary_key :id
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :event_id, :string, allow_nil?: false, public?: true
    attribute :payload, :map, allow_nil?: false, public?: true
    attribute :processed, :boolean, default: false, public?: true
  end

  actions do
    create :ingest do
      accept [:provider, :event_id, :payload]
      change set_attribute(:processed, true)
      argument :idempotency_key, :string, allow_nil?: false
    end
  end

  onetime do
    protect :ingest do
      strategy :idempotency
      scope [{:attribute, :provider}, {:static, "webhook"}]
      key {:client, :idempotency_key}
      # Bind the fingerprint to the full request so a replay with a mutated payload conflicts.
      fingerprint attributes: [:event_id, :payload]
      response MyApp.WebhookCodec,
        fields: [:id, :processed],
        classify: MyApp.WebhookClassifier
      retention {7, :day}
    end
  end
end
```

Map the provider's `event_id` to the `idempotency_key` argument at the controller edge. A
redelivery with the same `event_id` and the same payload replays the stored result
(`AshOnetime.replayed?/1` returns `true`); a redelivery with the same key but a *different*
payload returns `:key_reused_with_different_request` and never re-processes.

## Recipe 3 — Single-use redemption link

A `redeem` action that must succeed at most once per proof, regardless of how many times the
client retries. This is one-time *nonce* protection, not idempotency: there is no stored
result to replay, only a fail-closed spend of the proof.

```elixir
defmodule MyApp.Redemption do
  use Ash.Resource,
    domain: MyApp.Rewards,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  attributes do
    uuid_primary_key :id
    attribute :link_id, :string, allow_nil?: false, public?: true
    attribute :redeemed_at, :utc_datetime_usec, public?: true
  end

  actions do
    update :redeem do
      accept []
      argument :proof, :string, allow_nil?: false
      change set_attribute(:redeemed_at, DateTime.utc_now())
    end
  end

  onetime do
    protect :redeem do
      strategy :one_time_nonce
      scope [{:static, "redemption"}]
      # The proof is verified by MyApp.ProofVerifier, which returns trusted AshOnetime.Verified
      # facts. The action argument carries raw token material; it cannot assert verification.
      key {:verified, :proof, MyApp.ProofVerifier}
      window max_age: {10, :minute}, clock_skew: {15, :second}
    end
  end
end
```

At the call boundary, the first redemption succeeds (`replayed?/1` is `nil` — a nonce has no
replay signal); every retry of the same proof returns `:nonce_already_used`:

```elixir
case Ash.update(Ash.Changeset.for_update(link, :redeem, %{proof: proof})) do
  {:ok, redemption} ->
    {:ok, redemption}

  {:error, error} ->
    case AshOnetime.Error.code(error) do
      :nonce_already_used -> {:conflict, "this redemption link has already been used"}
      :request_in_progress -> {:conflict, "a redemption for this proof is already processing"}
      nil -> {:internal_server_error, "unexpected error"}
    end
end
```

## Choosing between idempotency and one-time nonce

The two strategies are not interchangeable. See [Idempotency](idempotency.md) and
[One-time nonces](one-time-nonces.md) for the full contracts. The short version:

- **Idempotency** — safe retries of an effectful action. The first execution stores its
  result; retries replay it. Use when the client may retry (network failure, timeout) and you
  want the *same* logical effect and response each time.
- **One-time nonce** — at-most-once admission of a verified request. The first spend
  succeeds; every reuse is rejected. Use when the action must never repeat even if the client
  retries (single-use coupons, one-time redemptions, anti-replay of a captured request).

Never use idempotency's stored-result replay as anti-replay protection, and never let a nonce
inherit idempotency's optional untracked failure direction. See
[usage-rules.md](../usage-rules.md).
