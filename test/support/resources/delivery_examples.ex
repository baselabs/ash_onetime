defmodule AshOnetime.Test.DeliveryExamples.Producer do
  @moduledoc false
  @behaviour AshOnetime.Producer

  # A fresh random value per execution. An observer, when set, receives only the fact of
  # the call and the trusted context's keys, never the value.
  @impl true
  def produce(_subject, context) do
    if observer = Process.get({__MODULE__, :observer}),
      do: send(observer, {:produced, self(), Map.keys(context) |> Enum.sort()})

    {:ok, %{secret: :crypto.strong_rand_bytes(32)}}
  end
end

defmodule AshOnetime.Test.DeliveryExamples.GenericRun do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: {:ok, Ash.ActionInput.get_argument(input, :value)}
end

defmodule AshOnetime.Test.DeliveryExamples.OuterRun do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  # The outer action fails after its policy check ran, so Ash rolls back the transaction
  # the check ran in.
  @impl true
  def run(_input, _opts, _context),
    do: {:error, Ash.Error.Invalid.exception(errors: [])}
end

defmodule AshOnetime.Test.DeliveryExamples.NestedDeliverCheck do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  # Runs a nested `AshOnetime.deliver/2` from inside a policy check, under the outer
  # action's transaction. The subject comes from the process dictionary; the result goes
  # back to the test process the same way.
  @impl true
  def describe(_opts), do: "runs a nested executing-only delivery"

  @impl true
  def match?(_actor, _context, _opts) do
    case Process.delete({__MODULE__, :subject}) do
      nil ->
        true

      build when is_function(build, 0) ->
        Process.put({__MODULE__, :result}, AshOnetime.deliver(build.()))
        true
    end
  end
end

defmodule AshOnetime.Test.DeliveryExamples.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOnetime.Test.DeliveryExamples.Resource
    resource AshOnetime.Test.DeliveryExamples.Outer
  end
end

defmodule AshOnetime.Test.DeliveryExamples.Resource do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.DeliveryExamples.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "ash_onetime_delivery_examples"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :amount, :integer, public?: true, allow_nil?: false
    attribute :retired, :boolean, public?: true, allow_nil?: false, default: false
  end

  actions do
    defaults [:read]

    create :seed do
      accept [:amount]
    end

    create :issue do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "example"
      accept [:amount]
    end

    update :rotate do
      transaction? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "example"
      accept [:amount]
    end

    destroy :revoke do
      transaction? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "example"
    end

    destroy :retire do
      transaction? true
      soft? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "example"
      change set_attribute(:retired, true)
    end

    action :mint, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.DeliveryExamples.GenericRun, []}
    end
  end

  onetime do
    protect :issue do
      strategy :idempotency
      scope([{:static, "delivery"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :rotate do
      strategy :idempotency
      scope([{:static, "delivery"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :revoke do
      strategy :idempotency
      scope([{:static, "delivery"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :retire do
      strategy :idempotency
      scope([{:static, "delivery"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :mint do
      strategy :idempotency
      scope([{:static, "delivery"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end
  end
end

defmodule AshOnetime.Test.DeliveryExamples.Outer do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.DeliveryExamples.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # The generic action never reads or writes this table; the data layer gives the action
  # the repository's transaction.
  postgres do
    table "ash_onetime_delivery_outer"
    repo AshOnetime.Test.Repo
  end

  actions do
    action :outer, :integer do
      transaction? true
      run {AshOnetime.Test.DeliveryExamples.OuterRun, []}
    end
  end

  policies do
    policy action(:outer) do
      authorize_if AshOnetime.Test.DeliveryExamples.NestedDeliverCheck
    end
  end
end
