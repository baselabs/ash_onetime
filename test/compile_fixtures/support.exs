defmodule AshOnetime.CompileFixture.Tenant do
  def resolve(_subject, _context), do: {:ok, "tenant"}
end

defmodule AshOnetime.CompileFixture.Verifier do
  def verify(_token, _context), do: {:error, :invalid}
  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.SeparatedHMAC do
  def verify(_token, _context), do: {:error, :invalid}
  def mint(_context), do: {:error, :invalid}
  def algorithm, do: :hmac_sha256
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.MissingVerifier do
  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.Minter do
  def mint(_context), do: {:error, :invalid}
  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.FreshMinter do
  def mint(_context) do
    {:ok,
     %AshOnetime.Verified{
       key: :crypto.strong_rand_bytes(32),
       issued_at: DateTime.utc_now(),
       verifier_id: "fresh-fixture-minter"
     }}
  end

  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.MissingMinter do
  def algorithm, do: :ed25519
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.BadAlgorithm do
  def verify(_token, _context), do: {:error, :invalid}
  def algorithm, do: :rsa
  def trust_model, do: :separated
end

defmodule AshOnetime.CompileFixture.BadTrust do
  def verify(_token, _context), do: {:error, :invalid}
  def algorithm, do: :ed25519
  def trust_model, do: :shared_secret
end

defmodule AshOnetime.CompileFixture.Codec do
  def format_tag, do: "fixture"
  def encode(_value, _fields, _context), do: {:ok, <<>>}
  def decode(_payload, _fields, _type, _context), do: {:ok, :ok}
end

defmodule AshOnetime.CompileFixture.MissingCodec do
  def format_tag, do: "fixture"
  def encode(_value, _fields, _context), do: {:ok, <<>>}
end

defmodule AshOnetime.CompileFixture.EmptyTagCodec do
  def format_tag, do: ""
  def encode(_value, _contract, _opts), do: {:ok, format_tag(), <<>>}
  def decode(_tag, _payload, _contract, _opts), do: {:ok, :ok}
end

defmodule AshOnetime.CompileFixture.ColonTagCodec do
  def format_tag, do: "bad:tag"
  def encode(_value, _contract, _opts), do: {:ok, format_tag(), <<>>}
  def decode(_tag, _payload, _contract, _opts), do: {:ok, :ok}
end

defmodule AshOnetime.CompileFixture.LongTagCodec do
  def format_tag, do: String.duplicate("a", 82)
  def encode(_value, _contract, _opts), do: {:ok, format_tag(), <<>>}
  def decode(_tag, _payload, _contract, _opts), do: {:ok, :ok}
end

defmodule AshOnetime.CompileFixture.Classifier do
  def classify(value, _context), do: {:store, value}
end

defmodule AshOnetime.CompileFixture.MissingClassifier do
  def classify(_value), do: :store
end

defmodule AshOnetime.CompileFixture.External do
  def execute(_operation_key, _input, _context), do: {:error, :not_implemented}
  def recover(_operation_key, _input, _context), do: {:error, :not_implemented}
end

defmodule AshOnetime.CompileFixture.MissingExternal do
  def execute(_operation_key, _input, _context), do: {:error, :not_implemented}
end

defmodule AshOnetime.CompileFixture.WrongExecuteArityExternal do
  def execute(_input, _context), do: {:error, :not_implemented}
  def recover(_operation_key, _input, _context), do: :unknown
end

defmodule AshOnetime.CompileFixture.WrongRecoverArityExternal do
  def execute(_operation_key, _input, _context), do: {:error, :outcome_unknown}
  def recover(_input, _context), do: :unknown
end

defmodule AshOnetime.CompileFixture.UnsafeChange do
  use Ash.Resource.Change
  def change(changeset, _opts, _context), do: changeset
end

defmodule AshOnetime.CompileFixture.SafeChange do
  use Ash.Resource.Change
  def change(changeset, _opts, _context), do: changeset
  def replay_safety(_opts), do: :pure

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.CompileFixture.InvalidSafetyChange do
  use Ash.Resource.Change
  def change(changeset, _opts, _context), do: changeset
  def replay_safety(_opts), do: :unknown

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.CompileFixture.AroundChange do
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    Ash.Changeset.around_action(changeset, fn pending, callback -> callback.(pending) end,
      prepend?: true
    )
  end

  def replay_safety(_opts), do: :replay_aware

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: true, marker: :consumed}
end

defmodule AshOnetime.CompileFixture.NonceNonAroundChange do
  use Ash.Resource.Change

  def change(changeset, _opts, _context), do: changeset

  def replay_capabilities(_opts),
    do: %{notifications: true, effects: true, around_action: false, marker: :unused}
end

defmodule AshOnetime.CompileFixture.PureNotificationChange do
  use Ash.Resource.Change
  def change(changeset, _opts, _context), do: changeset
  def replay_safety(_opts), do: :pure

  def replay_capabilities(_opts),
    do: %{notifications: true, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.CompileFixture.UnclassifiedProducerChange do
  use Ash.Resource.Change
  def change(changeset, _opts, _context), do: changeset
  def replay_safety(_opts), do: :replay_aware
end

defmodule AshOnetime.CompileFixture.MarkerBlindProducerChange do
  use Ash.Resource.Change
  def change(changeset, _opts, _context), do: changeset
  def replay_safety(_opts), do: :replay_aware

  def replay_capabilities(_opts),
    do: %{notifications: true, effects: true, around_action: false, marker: :unused}
end

defmodule AshOnetime.CompileFixture.UnsafePreparation do
  use Ash.Resource.Preparation
  def prepare(query, _opts, _context), do: query
  def supports(_opts), do: [Ash.Query, Ash.ActionInput]
end

defmodule AshOnetime.CompileFixture.InvalidSafetyPreparation do
  use Ash.Resource.Preparation
  def prepare(query, _opts, _context), do: query
  def supports(_opts), do: [Ash.Query, Ash.ActionInput]
  def replay_safety(_opts), do: :unknown

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.CompileFixture.Context do
  def build, do: %{source: :fixture}
  def zero, do: 0
  def validate(_subject, _context), do: :ok
end

defmodule AshOnetime.CompileFixture.UnsafeValidation do
  use Ash.Resource.Validation
  def validate(_subject, _opts, _context), do: :ok
  def describe(_opts), do: [message: "must pass fixture validation", vars: []]
end

defmodule AshOnetime.CompileFixture.Run do
  use Ash.Resource.Actions.Implementation
  def run(_input, _opts, _context), do: {:ok, :ok}
end

defmodule AshOnetime.CompileFixture.Notifier do
  use Ash.Notifier
  def notify(_notification), do: :ok
end

defmodule AshOnetime.CompileFixture do
  alias Ash.Resource.Validation.Function, as: FunctionValidation
  alias AshOnetime.CompileFixture.Context, as: FixtureContext

  defmacro resource(name, options \\ [], do: body) do
    data_layer = Keyword.get(options, :data_layer, AshPostgres.DataLayer)
    actions = options |> Keyword.get(:actions) |> actions_ast()
    attributes = options |> Keyword.get(:attributes) |> attributes_ast()
    multitenancy = options |> Keyword.get(:multitenancy) |> multitenancy_ast()
    lifecycle = options |> Keyword.get(:lifecycle) |> lifecycle_ast()

    postgres =
      if data_layer == AshPostgres.DataLayer do
        quote do
          postgres do
            table "compile_fixture"
            repo AshOnetime.TestRepo
          end
        end
      end

    quote do
      defmodule unquote(name) do
        use Ash.Resource,
          domain: nil,
          data_layer: unquote(data_layer),
          extensions: [AshOnetime.Resource]

        unquote(postgres)
        unquote(attributes)
        unquote(multitenancy)
        unquote(lifecycle)
        unquote(actions)
        unquote(body)
      end
    end
  end

  defp default_attributes do
    quote do
      attributes do
        uuid_primary_key :id
        attribute :account_id, :uuid, public?: true
        attribute :amount, :integer, public?: true
      end
    end
  end

  defp default_actions do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
        end

        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(nil), do: default_actions()

  defp actions_ast(:read) do
    quote do
      actions do
        read :lookup
      end
    end
  end

  defp actions_ast(:nontransactional) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          transaction? false
        end
      end
    end
  end

  defp actions_ast(:nontransactional_generic) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? false
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:external_nonce_matrix) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
        end

        update :adjust do
          transaction? true
          require_atomic? false
          argument :proof, :string
          accept [:amount]
        end

        destroy :remove do
          transaction? true
          argument :proof, :string
        end

        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:unsafe_relationship) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change {Ash.Resource.Change.ManageRelationship, relationship: :owner, argument: :owner}
        end
      end
    end
  end

  defp actions_ast(:unsafe_hook) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change AshOnetime.CompileFixture.UnsafeChange
        end
      end
    end
  end

  defp actions_ast(:notifier) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          notifiers [AshOnetime.CompileFixture.Notifier]
        end
      end
    end
  end

  defp actions_ast(kind)
       when kind in [
              :around_change,
              :nonce_non_around,
              :pure_notification,
              :unclassified_producer,
              :marker_blind
            ] do
    module =
      case kind do
        :around_change -> AshOnetime.CompileFixture.AroundChange
        :nonce_non_around -> AshOnetime.CompileFixture.NonceNonAroundChange
        :pure_notification -> AshOnetime.CompileFixture.PureNotificationChange
        :unclassified_producer -> AshOnetime.CompileFixture.UnclassifiedProducerChange
        :marker_blind -> AshOnetime.CompileFixture.MarkerBlindProducerChange
      end

    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change unquote(module)
        end
      end
    end
  end

  defp actions_ast(:pipeline_hook) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          pipe_through :unsafe_replay
        end
      end
    end
  end

  defp actions_ast(:inline_change) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change fn changeset, _context -> changeset end
        end
      end
    end
  end

  defp actions_ast(:invalid_change) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change AshOnetime.CompileFixture.InvalidSafetyChange
        end
      end
    end
  end

  defp actions_ast(:set_attribute_callable) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change set_attribute(:amount, {AshOnetime.CompileFixture.Context, :build, []})
        end
      end
    end
  end

  defp actions_ast(:set_context_callable) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change set_context({AshOnetime.CompileFixture.Context, :build, []})
        end
      end
    end
  end

  defp actions_ast(:relate_actor) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          change relate_actor(:owner)
        end
      end
    end
  end

  defp actions_ast(:unsafe_preparation) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          prepare AshOnetime.CompileFixture.UnsafePreparation
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:invalid_preparation) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          prepare AshOnetime.CompileFixture.InvalidSafetyPreparation
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:inline_preparation) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          prepare fn query, _context -> query end
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:set_context_preparation) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          prepare set_context({AshOnetime.CompileFixture.Context, :build, []})
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:pipeline_preparation) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          pipe_through :unsafe_replay
          run AshOnetime.CompileFixture.Run
        end
      end
    end
  end

  defp actions_ast(:reactor_generic) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          run Reactor
        end
      end
    end
  end

  defp actions_ast(:unsafe_validation) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          validate AshOnetime.CompileFixture.UnsafeValidation
        end
      end
    end
  end

  defp actions_ast(:unsafe_function_validation) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]

          validate {FunctionValidation, fun: {AshOnetime.CompileFixture.Context, :validate, []}}
        end
      end
    end
  end

  defp actions_ast(:unsafe_compare_validation) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          validate compare(:amount, greater_than: &FixtureContext.zero/0)
        end
      end
    end
  end

  defp actions_ast(:unsafe_nested_validation) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          validate AshOnetime.CompileFixture.UnsafeValidation
        end
      end
    end
  end

  defp actions_ast(:unsafe_where_validation) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]

          validate present(:amount),
            where: [AshOnetime.CompileFixture.UnsafeValidation]
        end
      end
    end
  end

  defp actions_ast(:pipeline_validation) do
    quote do
      actions do
        create :charge do
          argument :idempotency_key, :string
          accept [:account_id, :amount]
          pipe_through :unsafe_validation
        end
      end
    end
  end

  defp actions_ast(:inline_generic) do
    quote do
      actions do
        action :redeem, :atom do
          argument :proof, :string
          transaction? true
          run fn _input, _context -> {:ok, :ok} end
        end
      end
    end
  end

  defp actions_ast(:reserved_argument) do
    actions_ast({:reserved_argument, :verification_state})
  end

  defp actions_ast({:reserved_argument, name}) do
    quote do
      actions do
        create :charge do
          argument unquote(name), :string
          accept [:account_id, :amount]
        end
      end
    end
  end

  defp actions_ast(:reserved_attribute) do
    actions_ast({:reserved_attribute, :algorithm})
  end

  defp actions_ast({:reserved_attribute, name}) do
    quote do
      actions do
        create :charge do
          accept [unquote(name)]
        end
      end
    end
  end

  # A reserved-named attribute DECLARED on the resource but NOT accepted by the protected
  # action. M2: this must fail compilation (the runtime guard reject_reserved/1 checks
  # changeset.attributes, but the attribute could be set by a change/default on another
  # action — fail it at compile time to match the runtime guard).
  defp actions_ast({:reserved_attribute_unaccepted, _name}) do
    quote do
      actions do
        create :charge do
          accept []
        end
      end
    end
  end

  defp multitenancy_ast(nil), do: nil

  defp multitenancy_ast(:attribute_account_id) do
    quote do
      multitenancy do
        strategy :attribute
        attribute :account_id
      end
    end
  end

  defp attributes_ast(nil), do: default_attributes()

  defp attributes_ast(:reserved) do
    attributes_ast({:reserved, :algorithm})
  end

  defp attributes_ast({:reserved, name}) do
    quote do
      attributes do
        uuid_primary_key :id
        attribute unquote(name), :string, public?: true
      end
    end
  end

  defp attributes_ast(:response_fields) do
    quote do
      attributes do
        uuid_primary_key :id
        attribute :account_id, :uuid, public?: true
        attribute :amount, :integer, public?: true
        attribute :private_note, :string, public?: false
        attribute :secret_note, :string, public?: true, sensitive?: true
      end

      relationships do
        belongs_to :owner, __MODULE__, public?: true
      end
    end
  end

  defp lifecycle_ast(nil), do: nil

  defp lifecycle_ast(:global_hook) do
    quote do
      changes do
        change AshOnetime.CompileFixture.UnsafeChange
      end
    end
  end

  defp lifecycle_ast(:global_around) do
    quote do
      changes do
        change AshOnetime.CompileFixture.AroundChange
      end
    end
  end

  defp lifecycle_ast(:global_pure_notification) do
    quote do
      changes do
        change AshOnetime.CompileFixture.PureNotificationChange
      end
    end
  end

  defp lifecycle_ast(:pipeline_hook) do
    quote do
      pipelines do
        pipeline :unsafe_replay do
          change AshOnetime.CompileFixture.UnsafeChange
        end
      end
    end
  end

  defp lifecycle_ast(:global_relationship) do
    quote do
      changes do
        change {Ash.Resource.Change.ManageRelationship, relationship: :owner, argument: :owner}
      end
    end
  end

  defp lifecycle_ast(:pipeline_relationship) do
    quote do
      pipelines do
        pipeline :unsafe_replay do
          change {Ash.Resource.Change.ManageRelationship, relationship: :owner, argument: :owner}
        end
      end
    end
  end

  defp lifecycle_ast(:global_preparation) do
    quote do
      preparations do
        prepare AshOnetime.CompileFixture.UnsafePreparation, on: :action
      end
    end
  end

  defp lifecycle_ast(:pipeline_preparation) do
    quote do
      pipelines do
        pipeline :unsafe_replay do
          prepare AshOnetime.CompileFixture.UnsafePreparation
        end
      end
    end
  end

  defp lifecycle_ast(:global_validation) do
    quote do
      validations do
        validate AshOnetime.CompileFixture.UnsafeValidation, on: [:create]
      end
    end
  end

  defp lifecycle_ast(:pipeline_validation) do
    quote do
      pipelines do
        pipeline :unsafe_validation do
          validate AshOnetime.CompileFixture.UnsafeValidation
        end
      end
    end
  end
end
