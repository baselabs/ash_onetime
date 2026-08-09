defmodule AshOnetime.Resource.Response do
  @moduledoc """
  The normalized response contract for a protected action: the codec, the projected field
  allowlist, the result classifier, and codec options.

  Returned as the `:response` field of an `AshOnetime.Resource.Protection`. Built by the DSL
  from the `response` entity on a `protect` block; read with `AshOnetime.Resource.Info`.
  Response-size limits are declared on the `protect` block's `limits` option (the single,
  unified vocabulary), not on the `response` entity.
  """
  defstruct [:codec, :classify, :__spark_metadata__, fields: [], codec_opts: []]

  @type t :: %__MODULE__{
          codec: module(),
          classify: module() | nil,
          fields: [atom()],
          codec_opts: Keyword.t(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }
end

defmodule AshOnetime.Resource.Protection do
  @moduledoc """
  The normalized, per-action keyed-effect declaration produced by an `onetime` `protect` block.

  One `Protection` exists per protected action, carrying its strategy (`:idempotency` or
  `:one_time_nonce`), identity scope, key source, fingerprint, response contract, retention,
  replay window, external-effect module, store-failure policy, and limits. The struct is the
  return type of `AshOnetime.Resource.Info.protection/2` and `protections/1`; read its fields
  directly for introspection.
  """
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
    commit: :with_action,
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
          commit: :with_action | :independent,
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
          "Codec-specific options forwarded to the codec: the third argument to `encode/3` " <>
            "and the fourth argument to `decode/4`."
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
      commit: [
        type: {:in, [:with_action, :independent]},
        default: :with_action,
        doc:
          "Nonce commit boundary. `:with_action` (default) commits the nonce claim inside the " <>
            "protected action's transaction, so an action-body failure rolls the spend back " <>
            "(correct for a single-use authenticator whose retry bears a fresh proof). " <>
            "`:independent` commits the claim in its own transaction before the action body " <>
            "runs, so a body failure leaves the proof spent for the acceptance window — " <>
            "RFC 9449 §11.1 request-attempt scope (the DPoP replay fence). Applies to " <>
            "`:one_time_nonce` only; rejected for `:idempotency`."
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
          "The single, unified vocabulary of size bounds for this protection. Valid keys: " <>
            "`max_key_bytes`, `max_token_bytes`, `max_scope_components`, `max_fingerprint_bytes`, " <>
            "`verifier_timeout_ms`, and `max_cache_entry_bytes` bound the key/verification/cache " <>
            "paths; `max_response_bytes`, `max_response_depth`, `max_response_nodes`, " <>
            "`max_response_entries`, and `max_response_scalar_bytes` bound the response payload " <>
            "(structural limits). Each is a positive integer at or below its package ceiling. " <>
            "Unknown keys are rejected at compile time. Response bounds apply only to idempotent " <>
            "strategies (which store a payload); nonce strategies accept the keys but do not " <>
            "encode a response."
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
