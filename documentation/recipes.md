# Recipes

Four end-to-end patterns — payment idempotency, webhook deduplication, redemption-link
single-use, and external effect via a transactional outbox — showing the resource DSL, a
response codec, a classifier, and the call-site result handling together. The codec and
classifier shapes here match the `AshOnetime.Codec` behaviour and the `classify/2` contract
on `AshOnetime.ResponseClassifier`; copy them and adapt the encode/decode/classify logic to
your domain.

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

## Recipe 4 — External effect via a transactional outbox

A protected action whose side effect must publish only if the action commits, delivered by
your own worker (an Oban job is the natural carrier). The composition: the outbox row **is**
the peer. The adapter's `execute/3` inserts a durable outbox row keyed by the operation key
through the action's own repository — so the row commits with the action and rolls back with
it — and `recover/3` reads that row back after the dust settles. The package admits the
action once per key; the outbox row gates delivery; the worker owns retry and delivery
policy.

```elixir
defmodule MyApp.NotificationOutbox do
  use Ash.Resource,
    domain: MyApp.Notifications,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "notification_outbox"
    repo MyApp.Repo
  end

  attributes do
    # The operation key (the package-supplied claim UUID) is the primary key: the
    # insert IS the atomic key claim defense 2 requires.
    uuid_primary_key :operation_key
    attribute :payload, :map, allow_nil?: false, public?: true
    attribute :delivered_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read]

    update :mark_delivered do
      change set_attribute(:delivered_at, DateTime.utc_now())
    end
  end
end

defmodule MyApp.NotificationOutboxAdapter do
  @behaviour AshOnetime.ExternalEffect

  alias MyApp.NotificationOutbox

  # The insert is local, but it is not automatically bounded: a contended key blocks
  # until the holding transaction ends (the same serialization an atomic key claim
  # provides), so the adapter caps the wait like any other peer call.
  @insert_timeout :timer.seconds(10)

  @impl true
  def execute(operation_key, subject, _context) do
    payload = build_payload(subject)

    # Insert through the caller's repository: this callback runs INSIDE the caller's open
    # transaction (see the external-effects guide), so the outbox row commits with the
    # action and a rolled-back action leaves no row. The insert is a bare Ecto insert —
    # deliberately, because the adapter (not Ash changesets) owns the key — which also
    # means Ash-level defaults do not run: set inserted_at explicitly.
    #
    # on_conflict: :nothing IS the atomic key claim: a concurrent same-key execute (an
    # honest in-flight retry, per the external-effects guide) blocks on this row and then
    # converges on the winner's row — both callers return the SAME receipt, and the loser
    # never errors and never duplicates.
    {:ok, _row} =
      MyApp.Repo.insert(
        %NotificationOutbox{
          operation_key: operation_key,
          payload: payload,
          inserted_at: DateTime.utc_now()
        },
        on_conflict: :nothing,
        conflict_target: :operation_key,
        timeout: @insert_timeout
      )

    case MyApp.Repo.get(NotificationOutbox, operation_key, timeout: @insert_timeout) do
      nil -> {:error, :outcome_unknown}
      row -> {:ok, %{outbox_id: row.operation_key, status: "accepted"}}
    end
  end

  @impl true
  def recover(operation_key, _subject, _context) do
    case MyApp.Repo.get(NotificationOutbox, operation_key, timeout: @insert_timeout) do
      nil -> :absent
      row -> {:ok, %{outbox_id: row.operation_key, status: "accepted"}}
    end
  end

  # The subject is an ActionInput for generic actions and a Changeset for create/update/
  # destroy — build the payload from whichever surface the protected action uses.
  defp build_payload(%Ash.ActionInput{} = subject),
    do: %{value: Ash.ActionInput.get_argument(subject, :value)}

  defp build_payload(%Ash.Changeset{} = subject),
    do: %{value: Ash.Changeset.get_argument(subject, :value)}
end
```

`recover/3`'s `:absent` is authoritative for a **settled** history: once the original
request's transaction has committed or rolled back, the row's absence proves the effect
never landed (a rolled-back action leaves no row, so a retry's recovery truthfully returns
`:absent` and re-executes). While the original is still in flight, the concurrent case is
handled where it must be — inside `execute/3`'s atomic key claim — not by `recover/3`,
which runs in a different transaction and cannot see an uncommitted row.

The protected action is Recipe 1's shape with `external_effect MyApp.NotificationOutboxAdapter`
added. The stored response is the **acceptance receipt** — which pins two classifier rules
this recipe must not get wrong:

- **Classify the acceptance receipt as `{:store, value}`.** Do NOT copy Recipe 1's
  classifier, which rejects anything not `"captured"`/`"settled"` — an acceptance-receipt
  action would reject every completion and strand the claim in `processing`.
- The classifier still applies to everything else: a `nil` or invalid receipt is rejected,
  and the action can run again.

Delivery is consumer-owned: an Oban job (or any worker) selects undelivered rows, delivers,
and calls `mark_delivered`. Surface delivery status through your own read path — a replay of
the admission returns the stored acceptance receipt, not the delivery state. The honest
end-to-end guarantee is **once-per-key admission + at-least-once delivery + receiver-side
idempotency**; neither this package nor any outbox can make an at-most-once *delivery*
claim (a worker that dies between delivering and marking delivers twice on retry), which is
exactly why the admission/delivery boundary exists.

Two boundaries to keep the composition correct:

- **Cross-generation deduplication is the receiver's.** Within one admission's retention,
  retries replay the stored receipt and never insert a second row. After the claim is
  cleaned (retention) or reaped, a retry of the same logical key mints a **new** claim UUID
  — the outbox's operation-key primary key cannot recognize it, so a second row (and a
  second delivery) is possible no matter how long you retain the old row. If a logical
  notification must never deliver twice across claim generations, deduplicate on a stable
  logical key at the receiver (or give the outbox a separate unique index on the logical
  key and reuse the winning row in `execute/3`). Keep outbox rows long enough to reconcile
  undelivered work — and no longer claims to make that unnecessary.
- **One database, no peer call.** This composition suits a same-database outbox whose
  delivery worker is the only external reach. For a genuine cross-system effect (the peer is
  another service), use a real adapter against the peer's idempotency surface
  ([External effects](external-effects.md)) — the transactional-outbox trick depends on the
  insert committing in the action's own transaction.

For the same-database case with a host-owned transaction instead of a protected action, the
[`AshOnetime.Transaction`](transaction-owned-admission.md) boundary (including `claim_id/1`)
composes the same way, and [Custom lifecycles](custom-lifecycle.md) covers where effects can
live relative to the action's transaction.

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
