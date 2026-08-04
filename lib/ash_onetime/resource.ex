defmodule AshOnetime.Resource.Response do
  @moduledoc false
  defstruct [:codec, opts: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          codec: module(),
          opts: Keyword.t(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }
end

defmodule AshOnetime.Resource.Protection do
  @moduledoc false

  defstruct [
    :action,
    :strategy,
    :scope,
    :key,
    :fingerprint,
    :response,
    :retention,
    :window,
    :external_effect,
    on_definite_store_failure: :fail_closed,
    limits: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          action: atom(),
          strategy: :idempotency | :one_time_nonce,
          scope: [AshOnetime.Scope.component()],
          key: [AshOnetime.KeySource.source()],
          fingerprint: Keyword.t() | nil,
          response: AshOnetime.Resource.Response.t() | nil,
          retention: non_neg_integer() | nil,
          window: Keyword.t() | nil,
          external_effect: module() | nil,
          on_definite_store_failure: :fail_closed | :execute_untracked,
          limits: Keyword.t(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }
end

defmodule AshOnetime.Resource do
  @moduledoc """
  Spark resource extension for explicit idempotency and one-time nonce protection.

  A protected action must choose a strategy and a nonempty scope. Nonce protection has no
  stored-response or external-effect surface and always fails closed.
  """

  @response %Spark.Dsl.Entity{
    name: :response,
    describe: "Declares the response codec, field allowlist, and result classifier.",
    target: AshOnetime.Resource.Response,
    args: [:codec, {:optional, :opts, []}],
    schema: [
      codec: [type: :module, required: true],
      opts: [type: :keyword_list, default: []]
    ]
  }

  @protect %Spark.Dsl.Entity{
    name: :protect,
    describe: "Protects one effectful action with explicit keyed-effect semantics.",
    target: AshOnetime.Resource.Protection,
    args: [:action],
    entities: [response: [@response]],
    singleton_entity_keys: [:response],
    schema: [
      action: [type: :atom, required: true],
      strategy: [type: :atom],
      scope: [type: {:list, :any}],
      key: [type: :any],
      fingerprint: [type: :keyword_list],
      retention: [type: :any],
      window: [type: :keyword_list],
      external_effect: [type: :module],
      on_definite_store_failure: [
        type: {:in, [:fail_closed, :execute_untracked]},
        default: :fail_closed
      ],
      limits: [type: :keyword_list, default: []]
    ]
  }

  @onetime %Spark.Dsl.Section{
    name: :onetime,
    describe: "Protect effectful Ash actions with explicit keyed-effect semantics.",
    entities: [@protect]
  }

  use Spark.Dsl.Extension,
    sections: [@onetime],
    transformers: [AshOnetime.Resource.Transformer],
    verifiers: [AshOnetime.Resource.Verifier]
end
