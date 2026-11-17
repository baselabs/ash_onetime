defmodule AshOnetime.Test.ReturnExamples.IssueRun do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  # Persists a receipt in the action's own transaction and returns it, or returns nil
  # when the input asks for no receipt.
  @impl true
  def run(input, _opts, _context) do
    if Ash.ActionInput.get_argument(input, :present?) == false do
      {:ok, nil}
    else
      AshOnetime.Test.ReturnExamples.Receipt
      |> Ash.Changeset.for_create(
        :create,
        %{token: Ash.ActionInput.get_argument(input, :token)},
        tenant: input.tenant
      )
      |> Ash.create()
    end
  end
end

defmodule AshOnetime.Test.ReturnExamples.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOnetime.Test.ReturnExamples.Receipt
    resource AshOnetime.Test.ReturnExamples.Issuer
  end
end

defmodule AshOnetime.Test.ReturnExamples.Receipt do
  @moduledoc false

  # The record the issuer's generic actions return. Its fields are not the issuer's, so
  # the issuer's response projection is valid only against this resource (§2.7.6).
  use Ash.Resource,
    domain: AshOnetime.Test.ReturnExamples.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ash_onetime_return_receipts"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :token, :string, public?: true, allow_nil?: false
    attribute :code, :string, public?: false, default: "kept-private"
  end

  calculations do
    calculate :label, :string, expr("receipt-" <> token), public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:token]
    end
  end
end

defmodule AshOnetime.Test.ReturnExamples.Issuer do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.ReturnExamples.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  # The generic actions never read or write this table; the data layer gives them the
  # repository's transaction.
  postgres do
    table "ash_onetime_return_issuers"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  # The host carries a public `:token` of its own, so a verifier that checked a generic
  # action's response fields against the host instead of the returned resource would
  # still compile this file; the compile matrix (`returned_fields`,
  # `returned_action_field`) is what tells the two apart.
  attributes do
    uuid_primary_key :id
    attribute :token, :string, public?: true
  end

  actions do
    action :record, :struct do
      constraints instance_of: AshOnetime.Test.ReturnExamples.Receipt
      transaction? true
      argument :token, :string, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ReturnExamples.IssueRun, []}
    end

    action :maybe_record, :struct do
      constraints instance_of: AshOnetime.Test.ReturnExamples.Receipt
      transaction? true
      allow_nil? true
      argument :token, :string, allow_nil?: false
      argument :present?, :boolean, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ReturnExamples.IssueRun, []}
    end

    action :issue, :struct do
      constraints instance_of: AshOnetime.Test.ReturnExamples.Receipt
      transaction? true
      argument :token, :string, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.ReturnExamples.IssueRun, []}
    end
  end

  onetime do
    protect :record do
      strategy :idempotency
      scope([{:static, "return"}])
      key({:client, :request_key})
      fingerprint(arguments: [:token], attributes: [])

      response(AshOnetime.Codec.Resource,
        fields: [:id, :token],
        classify: AshOnetime.Test.StoreClassifier
      )

      retention(3_600)
    end

    protect :maybe_record do
      strategy :idempotency
      scope([{:static, "return"}])
      key({:client, :request_key})
      fingerprint(arguments: [:token, :present?], attributes: [])

      response(AshOnetime.Codec.Resource,
        fields: [:id, :token],
        classify: AshOnetime.Test.StoreClassifier
      )

      retention(3_600)
    end

    protect :issue do
      strategy :idempotency
      scope([{:static, "return"}])
      key({:client, :request_key})
      fingerprint(arguments: [:token], attributes: [])

      response(AshOnetime.Codec.Resource,
        fields: [:id, :token],
        classify: AshOnetime.Test.StoreClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end
  end
end
