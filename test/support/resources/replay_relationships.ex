defmodule AshOnetime.Test.ReplayRelationships.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOnetime.Test.ReplayRelationships.Parent
    resource AshOnetime.Test.ReplayRelationships.Related
  end
end

defmodule AshOnetime.Test.ReplayRelationships.Related do
  @moduledoc false
  use Ash.Resource,
    domain: AshOnetime.Test.ReplayRelationships.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "replay_related"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :parent_id, :uuid, public?: true
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept :*

      change after_action(fn _changeset, record, _context ->
               send(self(), {:relationship_child_written, record.label})
               {:ok, record}
             end)
    end
  end
end

defmodule AshOnetime.Test.ReplayRelationships.Parent do
  @moduledoc false
  require AshOnetime.Test.ReplayRelationships.Aware, warn: false
  require AshOnetime.Test.ReplayRelationships.BrokenPure, warn: false

  use Ash.Resource,
    domain: AshOnetime.Test.ReplayRelationships.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "replay_parents"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :value, :integer, public?: true
  end

  relationships do
    has_many :children, AshOnetime.Test.ReplayRelationships.Related do
      destination_attribute :parent_id
      public? true
    end

    belongs_to :owner, AshOnetime.Test.ReplayRelationships.Related do
      public? true
    end
  end

  actions do
    defaults [:read, create: :*]

    create :create_once do
      accept [:value]
      argument :request_key, :string, allow_nil?: false
      change AshOnetime.Test.ReplayRelationships.BrokenPure
      change AshOnetime.Test.ReplayRelationships.Aware
    end

    update :update_once do
      require_atomic? false
      accept [:value]
      argument :request_key, :string, allow_nil?: false
      change AshOnetime.Test.ReplayRelationships.BrokenPure
      change AshOnetime.Test.ReplayRelationships.Aware
    end

    destroy :destroy_once do
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      change AshOnetime.Test.ReplayRelationships.BrokenPure
      change AshOnetime.Test.ReplayRelationships.Aware
    end

    action :generic_once, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ActionExamples.GenericRun, []}
    end
  end

  policies do
    policy action(:create_once) do
      access_type :runtime
      authorize_if AshOnetime.Test.ReplayRelationships.ResultAllowed
    end

    policy action([:create, :read, :update_once, :destroy_once, :generic_once]) do
      authorize_if always()
    end
  end

  onetime do
    for action <- [:create_once, :update_once, :destroy_once] do
      protect action do
        strategy :idempotency
        scope([{:static, "relationships"}])
        key({:client, :request_key})
        fingerprint(arguments: [], attributes: [:value])

        response(AshOnetime.Test.Support.ResponseCodec,
          fields: [:id, :value, :owner_id],
          classify: AshOnetime.Test.Support.ResponseClassifier
        )

        retention(3_600)
      end
    end

    protect :generic_once do
      strategy :idempotency
      scope([{:static, "relationships"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
    end
  end
end
