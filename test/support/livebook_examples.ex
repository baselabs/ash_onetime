# Consumer modules mirroring documentation/livebooks/idempotency-and-nonces.livemd.
# Defined under test/support so they compile before protocol consolidation, and so the
# livebook walkthrough test (and the livebook itself) share one canonical shape.
defmodule AshOnetime.Test.LivebookExamples do
  @moduledoc false

  defmodule ChargeCodec do
    @moduledoc false
    @behaviour AshOnetime.Codec

    @impl true
    def format_tag, do: "charge-v1"

    @impl true
    def encode(value, _contract, _opts),
      do: {:ok, format_tag(), :erlang.term_to_binary(value)}

    @impl true
    def decode("charge-v1", payload, _contract, _opts),
      do: {:ok, :erlang.binary_to_term(payload, [:safe])}
  end

  defmodule ChargeClassifier do
    @moduledoc false
    def classify(value, _context), do: {:store, value}
  end

  defmodule ProofVerifier do
    @moduledoc false

    def verify(proof, _context) when is_binary(proof) do
      {:ok,
       %AshOnetime.Verified{
         key: proof,
         issued_at: DateTime.utc_now(),
         verifier_id: "demo-verifier"
       }}
    end

    def algorithm, do: :ed25519
    def trust_model, do: :separated
  end

  defmodule RedeemRun do
    @moduledoc false
    use Ash.Resource.Actions.Implementation

    @impl true
    def run(input, _opts, _context), do: {:ok, Ash.ActionInput.get_argument(input, :value)}
  end

  # A nonce action's body that always fails — used to demonstrate that a nonce spend rolls
  # back with the action transaction when the body (e.g. a downstream mint) errors.
  defmodule FailRun do
    @moduledoc false
    use Ash.Resource.Actions.Implementation

    @impl true
    def run(_input, _opts, _context),
      do: {:error, AshOnetime.Error.new(:downstream_failed, "the action body failed")}
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshOnetime.Test.LivebookExamples.Charge
    end
  end

  defmodule Charge do
    @moduledoc false

    use Ash.Resource,
      domain: AshOnetime.Test.LivebookExamples.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshOnetime.Resource]

    alias AshOnetime.Test.LivebookExamples.{
      ChargeClassifier,
      ChargeCodec,
      ProofVerifier,
      RedeemRun
    }

    postgres do
      table "demo_charges"
      repo AshOnetime.Test.Repo
    end

    multitenancy do
      strategy :context
    end

    attributes do
      uuid_primary_key :id
      attribute :account_id, :uuid, allow_nil?: false, public?: true
      attribute :amount, :integer, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read]

      create :charge do
        transaction? true
        argument :idempotency_key, :string, allow_nil?: false
        accept [:account_id, :amount]
      end

      action :redeem, :integer do
        transaction? true
        argument :value, :integer, allow_nil?: false
        argument :proof, :string, allow_nil?: false
        run {RedeemRun, []}
      end

      # A nonce action whose body always fails — used to demonstrate that a nonce spend
      # rolls back with the action transaction when the body (e.g. a downstream mint) errors.
      action :redeem_fail, :integer do
        transaction? true
        argument :value, :integer, allow_nil?: false
        argument :proof, :string, allow_nil?: false
        run {FailRun, []}
      end
    end

    onetime do
      protect :charge do
        strategy :idempotency
        scope([{:static, "charge"}, {:attribute, :account_id}])
        key({:client, :idempotency_key})
        fingerprint(attributes: [:account_id, :amount])
        response(ChargeCodec, fields: [:id, :account_id, :amount], classify: ChargeClassifier)
        retention({1, :hour})
      end

      protect :redeem do
        strategy :one_time_nonce
        scope([{:static, "redeem"}])
        key({:verified, :proof, ProofVerifier})
        window(max_age: {1, :hour}, clock_skew: {5, :second})
      end

      protect :redeem_fail do
        strategy :one_time_nonce
        scope([{:static, "redeem_fail"}])
        key({:verified, :proof, ProofVerifier})
        window(max_age: {1, :hour}, clock_skew: {5, :second})
      end
    end
  end
end
