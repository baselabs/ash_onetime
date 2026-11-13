defmodule AshOnetime.Test.HoldExamples do
  @moduledoc false

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Hold do
    @moduledoc false
    @behaviour AshOnetime.Hold
    def reference(%{reference: "invalid-reference"}, _context), do: {:hold, <<255>>}
    def reference(%{reference: "invalid-outcome"}, _context), do: :invalid

    def reference(%{reference: "invalid-callback"}, _context),
      do: raise(ArgumentError, "invalid callback")

    def reference(result, %{resource: _, action: action})
        when action in [:open, :external_open] do
      if result.open, do: {:hold, result.reference}, else: :none
    end
  end

  defmodule ExternalAdapter do
    @moduledoc false
    @behaviour AshOnetime.ExternalEffect
    alias AshOnetime.Test.ExternalPeer

    @impl true
    def execute(operation_key, subject, _context) do
      reference = Ash.Changeset.get_attribute(subject, :reference)

      {:ok,
       ExternalPeer.execute(subject.to_tenant, operation_key, %{
         reference: reference
       })}
    end

    @impl true
    def recover(operation_key, subject, _context),
      do: ExternalPeer.recover(subject.to_tenant, operation_key)
  end

  defmodule Operation do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    postgres do
      table "hold_operations"
      repo AshOnetime.Test.Repo
    end

    multitenancy do
      strategy :context
    end

    attributes do
      uuid_primary_key :id
      attribute :reference, :string, public?: true, allow_nil?: false
      attribute :open, :boolean, public?: true, default: true, allow_nil?: false
    end

    actions do
      defaults [:read]

      update :settle do
        accept []
        require_atomic? false
        change set_attribute(:open, false)
        change {AshOnetime.Changes.ReleaseHold, reference: :reference}
      end

      create :external_open do
        accept [:reference, :open]
        argument :request_key, :string, allow_nil?: false
      end

      create :open do
        accept [:reference, :open]
        argument :request_key, :string, allow_nil?: false
      end
    end

    onetime do
      protect :external_open do
        strategy :idempotency
        scope([{:static, "operations"}])
        key({:client, :request_key})
        fingerprint(attributes: [:reference, :open])

        response(AshOnetime.Codec.Resource,
          fields: [:id, :reference, :open],
          classify: AshOnetime.Test.Support.ResponseClassifier
        )

        retention({1, :hour})
        external_effect(ExternalAdapter)
        hold(Hold)
      end

      protect :open do
        strategy :idempotency
        scope([{:static, "operations"}])
        key({:client, :request_key})
        fingerprint(attributes: [:reference, :open])

        response(AshOnetime.Codec.Resource,
          fields: [:id, :reference, :open],
          classify: AshOnetime.Test.Support.ResponseClassifier
        )

        retention({1, :hour})
        hold(Hold)
      end
    end
  end

  defmodule Settlement do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: AshPostgres.DataLayer

    postgres do
      table "hold_settlements"
      repo AshOnetime.Test.Repo
    end

    multitenancy do
      strategy :context
    end

    attributes do
      uuid_primary_key :id
      attribute :reference, :string, public?: true, allow_nil?: false
    end

    actions do
      defaults [:read]

      create :settle do
        accept [:reference]
        change {AshOnetime.Changes.ReleaseHold, reference: :reference, resource: Operation}
      end

      create :settle_function do
        accept [:reference]
        change {AshOnetime.Changes.ReleaseHold, reference: & &1.reference, resource: Operation}
      end
    end
  end
end
