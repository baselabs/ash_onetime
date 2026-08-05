defmodule AshOnetime.Test.ActionExamples.GenericRun do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Ash.Error.Invalid
  alias AshOnetime.ExternalEffect
  alias AshOnetime.Test.{ExternalEffectSupport, ExternalPeer, Repo}
  alias Ecto.Adapters.SQL

  @impl true
  def run(input, opts, _context) do
    case Keyword.get(opts, :observer) || Process.get({__MODULE__, :observer}) do
      nil -> :ok
      observer -> send(observer, {:generic_run, input.arguments})
    end

    value = Ash.ActionInput.get_argument(input, :value)

    external_result = ExternalEffect.result(input)

    if match?({:ok, _result}, external_result) do
      {:ok, operation_key} = ExternalEffect.operation_key(input)
      :ok = ExternalEffectSupport.pause_local(operation_key)
      :ok = ExternalPeer.append_local!(input.to_tenant, operation_key, value)
    end

    if Process.get({__MODULE__, :ledger?}) do
      prefix = input.to_tenant

      SQL.query!(
        Repo,
        "INSERT INTO \"#{prefix}\".\"ash_onetime_generic_effect_ledger\" (value) VALUES ($1)",
        [value]
      )
    end

    if external_result != :error and ExternalEffectSupport.mode() == :fail_local do
      {:error, Invalid.exception(errors: [])}
    else
      generic_result(input, value)
    end
  end

  defp generic_result(input, value) do
    if Process.get({__MODULE__, :notify?}) do
      notification = %Ash.Notifier.Notification{
        resource: input.resource,
        action: input.action,
        data: value,
        for: [AshOnetime.Test.ActionExamples.Notifier]
      }

      {:ok, value, [notification]}
    else
      {:ok, value}
    end
  end
end

defmodule AshOnetime.Test.ActionExamples.Notifier do
  @moduledoc false
  use Ash.Notifier

  @impl true
  def notify(notification) do
    if observer = Process.get({__MODULE__, :observer}) do
      send(observer, {:generic_notification, notification.data})
    end

    :ok
  end
end

defmodule AshOnetime.Test.ActionExamples.Verifier do
  @moduledoc false

  def verify(token, _context) when is_binary(token) do
    if observer = Process.get({__MODULE__, :observer}), do: send(observer, {:verifier, token})

    {:ok,
     %AshOnetime.Verified{
       key: token,
       issued_at: DateTime.utc_now(),
       verifier_id: "action-verifier"
     }}
  end

  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.Test.ActionExamples.Minter do
  @moduledoc false

  def mint(_context) do
    if observer = Process.get({__MODULE__, :observer}), do: send(observer, :minter)

    {:ok,
     %AshOnetime.Verified{
       key: "minted-component",
       issued_at: DateTime.utc_now(),
       verifier_id: "action-minter"
     }}
  end

  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.Test.ActionExamples.StateInspection do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(input, _opts, _context) do
    Ash.ActionInput.after_action(input, fn final_input, result ->
      if observer = Process.get({__MODULE__, :observer}) do
        send(observer, {:admission_state, AshOnetime.Admission.state(final_input)})
      end

      {:ok, result}
    end)
  end

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  def replay_safety(_opts), do: :replay_aware

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: false, marker: :consumed}
end

defmodule AshOnetime.Test.ActionExamples.ExternalEffect do
  @moduledoc false
  @behaviour AshOnetime.ExternalEffect

  alias AshOnetime.Test.ExternalEffectSupport

  @impl true
  def execute(key, input, _context) do
    notify(:execute)
    ExternalEffectSupport.execute(key, input)
  end

  @impl true
  def recover(key, input, _context) do
    notify(:recover)
    ExternalEffectSupport.recover(key, input)
  end

  defp notify(operation) do
    if observer = Process.get({__MODULE__, :observer}), do: send(observer, {:external, operation})
  end
end

defmodule AshOnetime.Test.ActionExamples.TenantResolver do
  @moduledoc false

  def resolve(_subject, _context) do
    if observer = Process.get({__MODULE__, :observer}), do: send(observer, :tenant_resolver)
    {:ok, "resolved-tenant"}
  end
end

defmodule AshOnetime.Test.ActionExamples.DenyAuthorizer do
  @moduledoc false
  use Ash.Authorizer

  alias Ash.Error.Forbidden

  @impl true
  def initial_state(_actor, resource, action, domain),
    do: %{resource: resource, action: action, domain: domain}

  @impl true
  def strict_check_context(_state), do: []

  @impl true
  def strict_check(_state, _context), do: {:error, Forbidden.exception([])}

  @impl true
  def check_context(_state), do: []

  @impl true
  def check(state, _context), do: {:error, :forbidden, state}
end

defmodule AshOnetime.Test.ActionExamples.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOnetime.Test.ActionExamples.Resource
    resource AshOnetime.Test.ActionExamples.DeniedResource
  end
end

defmodule AshOnetime.Test.ActionExamples.DeniedResource do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.ActionExamples.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource],
    authorizers: [AshOnetime.Test.ActionExamples.DenyAuthorizer]

  postgres do
    table "ash_onetime_denied_examples"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :amount, :integer, public?: true, allow_nil?: false
  end

  actions do
    create :attempt do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      accept [:amount]
    end

    action :denied_redeem, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end
  end

  onetime do
    protect :attempt do
      strategy :idempotency
      scope([{:static, "denied"}])
      key({:client, :request_key})
      fingerprint(arguments: [], attributes: [:amount])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      external_effect(AshOnetime.Test.ActionExamples.ExternalEffect)
    end

    protect :denied_redeem do
      strategy :idempotency
      scope([{:static, "denied-generic"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      external_effect(AshOnetime.Test.ActionExamples.ExternalEffect)
    end
  end
end

defmodule AshOnetime.Test.ActionExamples.Resource do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.ActionExamples.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "ash_onetime_action_examples"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, public?: true, allow_nil?: false
    attribute :amount, :integer, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read]

    create :charge do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      argument :natural_key, :string, allow_nil?: false
      argument :external_key, :string, allow_nil?: false
      accept [:account_id, :amount]
    end

    create :external_charge do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      argument :proof, :string, allow_nil?: false
      accept [:account_id, :amount]
    end

    update :adjust do
      transaction? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      accept [:amount]
    end

    destroy :remove do
      transaction? true
      argument :request_key, :string, allow_nil?: false
    end

    action :redeem, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end

    action :redeem_other, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end

    action :scoped_redeem, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      argument :scope_key, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end

    action :consume, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :proof, :string, allow_nil?: false
      prepare AshOnetime.Test.ActionExamples.StateInspection
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end

    action :consume_other, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :proof, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end

    action :external_redeem, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      argument :proof, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end
  end

  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "charge"}, {:attribute, :account_id}])

      key([
        {:client, :request_key},
        {:argument, :natural_key},
        {:external, :external_key},
        {:attribute, :account_id}
      ])

      fingerprint(arguments: [], attributes: [:account_id, :amount])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :account_id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end

    protect :external_charge do
      strategy :idempotency
      scope([{:tenant, AshOnetime.Test.ActionExamples.TenantResolver}])

      key([
        {:client, :request_key},
        {:verified, :proof, AshOnetime.Test.ActionExamples.Verifier},
        {:minted, AshOnetime.Test.ActionExamples.Minter}
      ])

      fingerprint(arguments: [], attributes: [:account_id, :amount])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :account_id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      external_effect(AshOnetime.Test.ActionExamples.ExternalEffect)
    end

    protect :consume do
      strategy :one_time_nonce
      scope([{:static, "nonce-sensitive-scope"}])

      key([
        {:verified, :proof, AshOnetime.Test.ActionExamples.Verifier},
        {:minted, AshOnetime.Test.ActionExamples.Minter}
      ])

      window(max_age: 60, clock_skew: 5)
    end

    protect :consume_other do
      strategy :one_time_nonce
      scope([{:static, "nonce-sensitive-scope"}])
      key({:verified, :proof, AshOnetime.Test.ActionExamples.Verifier})
      window(max_age: 60, clock_skew: 5)
    end

    protect :redeem do
      strategy :idempotency
      scope([{:static, "redeem"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end

    protect :redeem_other do
      strategy :idempotency
      scope([{:static, "redeem"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end

    protect :scoped_redeem do
      strategy :idempotency
      scope([{:argument, :scope_key}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end

    protect :external_redeem do
      strategy :idempotency
      scope([{:tenant, AshOnetime.Test.ActionExamples.TenantResolver}])

      key([
        {:client, :request_key},
        {:verified, :proof, AshOnetime.Test.ActionExamples.Verifier},
        {:minted, AshOnetime.Test.ActionExamples.Minter}
      ])

      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      external_effect(AshOnetime.Test.ActionExamples.ExternalEffect)
    end

    protect :adjust do
      strategy :idempotency
      scope([{:static, "adjust"}])
      key({:client, :request_key})
      fingerprint(arguments: [], attributes: [:amount])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :account_id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end

    protect :remove do
      strategy :idempotency
      scope([{:static, "remove"}])
      key({:client, :request_key})
      fingerprint(arguments: [], attributes: [:account_id])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :account_id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end
  end
end
