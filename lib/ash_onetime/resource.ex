defmodule AshOnetime.Resource.Response do
  @moduledoc false
  defstruct [:codec, :classify, :limits, :__spark_metadata__, fields: [], codec_opts: []]

  @type t :: %__MODULE__{
          codec: module(),
          classify: module() | nil,
          fields: [atom()],
          codec_opts: Keyword.t(),
          limits: Keyword.t() | nil,
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
    args: [:codec],
    schema: [
      codec: [
        type: :module,
        required: true,
        doc:
          "The module implementing the response codec. Must export " <>
            "`format_tag/0`, `encode/3`, and `decode/4` and yield a tag the store accepts."
      ],
      fields: [
        type: {:list, :atom},
        default: [],
        doc:
          "The resource attributes projected into the stored/replayed response payload. " <>
            "Acts as the field allowlist; attributes not named here never enter the response."
      ],
      classify: [
        type: :module,
        doc:
          "The module exporting `classify/2` that decides whether a result is stored, " <>
            "rejected, or rolled back. Required for idempotency strategies."
      ],
      codec_opts: [
        type: :keyword_list,
        default: [],
        doc:
          "Codec-specific options forwarded to `encode/3` and `decode/4` as the fourth argument."
      ],
      limits: [
        type: {:or, [:keyword_list, {:literal, nil}]},
        doc:
          "Optional response-size bounds (e.g. `max_response_bytes`). When absent, the " <>
            "protect-level or trusted limits are used."
      ]
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
      action: [
        type: :atom,
        required: true,
        doc: "The name of the Ash action to protect (a create, update, destroy, or action)."
      ],
      strategy: [
        type: :atom,
        doc:
          "The keyed-effect strategy: `:idempotency` (replay-safe, stores a response) or " <>
            "`:one_time_nonce` (single-use, no stored response). Every protection must declare one."
      ],
      scope: [
        type: {:list, :any},
        doc:
          "The nonempty identity scope that partitions keyed effects. Components are static " <>
            "strings, tenant/attribute references, or resolver modules; missing scope is an error."
      ],
      key: [
        type: :any,
        doc:
          "The key source that names a single keyed effect within the scope: a client " <>
            "idempotency argument, a verified proof, or a minted token."
      ],
      fingerprint: [
        type: :keyword_list,
        doc:
          "Optional content fingerprint (`arguments:` / `attributes:` lists) that " <>
            "distinguishes distinct effects under the same key."
      ],
      retention: [
        type: :any,
        doc:
          "How long a stored idempotent response is retained before it may be re-executed, " <>
            "as a `{count, unit}` tuple (e.g. `{24, :hour}`)."
      ],
      window: [
        type: :keyword_list,
        doc:
          "Nonce replay window bounds: `max_age:` and `clock_skew:` as `{count, unit}` tuples. " <>
            "Applies to `:one_time_nonce` strategies."
      ],
      external_effect: [
        type: :module,
        doc:
          "Optional module exporting the external-effect contract for idempotent actions " <>
            "that must observe or reverse a side effect. Not available for nonce strategies."
      ],
      on_definite_store_failure: [
        type: {:in, [:fail_closed, :execute_untracked]},
        default: :fail_closed,
        doc:
          "What to do when the authoritative store is definitively unavailable: " <>
            "`:fail_closed` (reject) or `:execute_untracked` (run once with telemetry, no replay safety)."
      ],
      limits: [
        type: :keyword_list,
        default: [],
        doc:
          "Protect-level response-size bounds (e.g. `max_response_bytes`) applied unless the " <>
            "response declares its own `limits`."
      ]
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
