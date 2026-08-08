defmodule AshOnetime.Test.Support.TenantResolver do
  @moduledoc false

  def resolve(_subject, _context), do: {:ok, "tenant"}
end

defmodule AshOnetime.Test.Support.Verifier do
  @moduledoc false

  def verify(_token, _context), do: {:error, :not_implemented}
  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.Test.Support.ResponseCodec do
  @moduledoc false

  def format_tag, do: "test"
  def encode(value, _contract, _opts), do: {:ok, format_tag(), :erlang.term_to_binary(value)}

  def decode("test", payload, _contract, _opts),
    do: {:ok, :erlang.binary_to_term(payload, [:safe])}
end

defmodule AshOnetime.Test.Support.ResponseClassifier do
  @moduledoc false

  def classify(value, _context), do: {:store, value}
end

defmodule AshOnetime.Test.Support.GenericRun do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context), do: {:ok, :redeemed}
end

defmodule AshOnetime.Test.Support.Resource do
  @moduledoc false

  use Ash.Resource,
    domain: nil,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table "ash_onetime_dsl_examples"
    repo AshOnetime.TestRepo
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, public?: true, allow_nil?: false
    attribute :amount, :integer, public?: true, allow_nil?: false
  end

  pipelines do
    pipeline :safe_validation do
      validate present(:amount)
      validate compare(:amount, greater_than: 0)
      validate match(:idempotency_key, ~r/\S/)
    end
  end

  actions do
    create :charge do
      argument :idempotency_key, :string, allow_nil?: false
      accept [:account_id, :amount]
      pipe_through :safe_validation
    end

    action :redeem, :atom do
      argument :proof, :string, allow_nil?: false
      transaction? true
      run AshOnetime.Test.Support.GenericRun
    end
  end

  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:tenant, AshOnetime.Test.Support.TenantResolver}, {:attribute, :account_id}])
      key({:client, :idempotency_key})
      fingerprint(arguments: [], attributes: [:account_id, :amount])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :account_id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention({24, :hour})
    end

    protect :redeem do
      strategy :one_time_nonce
      scope([{:static, "redeem"}])
      key({:verified, :proof, AshOnetime.Test.Support.Verifier})
      window(max_age: {10, :minute}, clock_skew: {15, :second})
    end
  end
end
