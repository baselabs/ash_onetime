defmodule AshOnetime.Resource.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshOnetime.KeySource
  alias AshOnetime.Resource.Protection
  alias AshOnetime.Resource.Response
  alias AshOnetime.Scope
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @max_seconds 2_147_483_647
  @reserved_inputs [:key, :issued_at, :expires_at, :verification_state, :algorithm]
  @duration_factors [second: 1, minute: 60, hour: 3_600, day: 86_400]
  @limit_ceilings [
    max_key_bytes: 4_096,
    max_token_bytes: 65_536,
    max_scope_components: 16,
    max_fingerprint_bytes: 1_048_576,
    max_response_bytes: 16_777_216,
    verifier_timeout_ms: 30_000,
    max_cache_entry_bytes: 16_777_216
  ]
  @replay_safe_changes [
    Ash.Resource.Change.Atomic,
    Ash.Resource.Change.AtomicSet,
    Ash.Resource.Change.Filter,
    Ash.Resource.Change.Increment,
    Ash.Resource.Change.OptimisticLock,
    Ash.Resource.Change.PreventChange,
    Ash.Resource.Change.Select,
    Ash.Resource.Change.SetAttribute,
    Ash.Resource.Change.SetContext
  ]
  @replay_safe_preparations [Ash.Resource.Preparation.Build, Ash.Resource.Preparation.SetContext]
  @nonce_non_around_changes [
    Ash.Resource.Change.AfterAction,
    Ash.Resource.Change.AfterTransaction,
    Ash.Resource.Change.Atomic,
    Ash.Resource.Change.AtomicSet,
    Ash.Resource.Change.CascadeDestroy,
    Ash.Resource.Change.CascadeUpdate,
    Ash.Resource.Change.Filter,
    Ash.Resource.Change.GetAndLock,
    Ash.Resource.Change.GetAndLockForUpdate,
    Ash.Resource.Change.Increment,
    Ash.Resource.Change.Load,
    Ash.Resource.Change.ManageRelationship,
    Ash.Resource.Change.OptimisticLock,
    Ash.Resource.Change.PreventChange,
    Ash.Resource.Change.RelateActor,
    Ash.Resource.Change.Select,
    Ash.Resource.Change.SetAttribute,
    Ash.Resource.Change.SetContext,
    Ash.Resource.Change.UpdateChange
  ]
  @replay_safe_validations [
    Ash.Resource.Validation.ActionIs,
    Ash.Resource.Validation.ArgumentDoesNotEqual,
    Ash.Resource.Validation.ArgumentEquals,
    Ash.Resource.Validation.ArgumentIn,
    Ash.Resource.Validation.AttributeDoesNotEqual,
    Ash.Resource.Validation.AttributeEquals,
    Ash.Resource.Validation.AttributeIn,
    Ash.Resource.Validation.AttributesPresent,
    Ash.Resource.Validation.ByteSize,
    Ash.Resource.Validation.Changing,
    Ash.Resource.Validation.Confirm,
    Ash.Resource.Validation.DataOneOf,
    Ash.Resource.Validation.OneOf,
    Ash.Resource.Validation.PreFlightAuthorization,
    Ash.Resource.Validation.Present,
    Ash.Resource.Validation.StringLength
  ]
  @comparison_options [
    :greater_than,
    :greater_than_or_equal_to,
    :less_than,
    :less_than_or_equal_to,
    :is_equal,
    :is_not_equal
  ]

  @impl true
  def after?(Ash.Resource.Transformers.ResolvePipelines), do: true
  def after?(Ash.Resource.Transformers.DefaultAccept), do: true
  def after?(_transformer), do: false

  @impl true
  def transform(dsl_state) do
    with {:ok, protections} <- validate_and_normalize(dsl_state),
         {:ok, dsl_state} <- inject_all(dsl_state, protections) do
      index = %{
        ordered: protections,
        by_action: Map.new(protections, &{&1.action, &1})
      }

      {:ok, Transformer.persist(dsl_state, :ash_onetime_protections, index)}
    end
  end

  defp validate_and_normalize(dsl_state) do
    declared = Transformer.get_entities(dsl_state, [:onetime])

    with :ok <- reject_duplicates(declared, dsl_state) do
      protections = Enum.uniq_by(declared, & &1.action)

      Enum.reduce_while(protections, {:ok, []}, &normalize_next(&1, &2, dsl_state))
      |> case do
        {:ok, protections} -> {:ok, Enum.reverse(protections)}
        error -> error
      end
    end
  end

  defp normalize_next(protection, {:ok, normalized}, dsl_state) do
    case normalize_protection(protection, dsl_state) do
      {:ok, protection} -> {:cont, {:ok, [protection | normalized]}}
      {:error, %DslError{} = error} -> {:halt, {:error, error}}
    end
  end

  # mutation sentinel: duplicate-protection-guard
  defp reject_duplicates(protections, dsl_state),
    do: reject_duplicate_details(protections, dsl_state)

  defp reject_duplicate_details(protections, dsl_state) do
    case Enum.find(Enum.frequencies_by(protections, & &1.action), fn {_action, count} ->
           count > 1
         end) do
      nil ->
        :ok

      {action, _count} ->
        error(
          dsl_state,
          Enum.find(protections, &(&1.action == action)),
          :action,
          "action #{inspect(action)} can be protected only once"
        )
    end
  end

  defp normalize_protection(%Protection{} = protection, dsl_state) do
    actions = ResourceInfo.actions(dsl_state)
    action = Enum.find(actions, &(&1.name == protection.action))
    attributes = ResourceInfo.attributes(dsl_state)
    context = %{dsl_state: dsl_state, action: action, attributes: attributes}

    with :ok <- required(protection, dsl_state),
         :ok <- verify_data_layer(protection, dsl_state),
         :ok <- verify_action_shape(protection, context),
         :ok <- verify_reserved_inputs(protection, context),
         {:ok, scope} <- normalize_scope(protection, context),
         {:ok, key} <- normalize_key(protection, context),
         :ok <- verify_scope_callbacks(protection, scope, dsl_state),
         :ok <- verify_key_callbacks(protection, key, dsl_state),
         {:ok, limits} <- normalize_limits(protection, dsl_state),
         :ok <- verify_scope_bound(scope, limits, protection, dsl_state),
         {:ok, normalized} <-
           verify_strategy(%{protection | scope: scope, key: key, limits: limits}, context),
         :ok <- verify_lifecycle(normalized, context) do
      {:ok, normalized}
    end
  end

  defp required(protection, dsl_state) do
    cond do
      is_nil(protection.strategy) ->
        error(dsl_state, protection, :strategy, "strategy is required and has no default")

      protection.strategy not in [:idempotency, :one_time_nonce] ->
        error(
          dsl_state,
          protection,
          :strategy,
          "strategy must be :idempotency or :one_time_nonce"
        )

      is_nil(protection.scope) ->
        error(dsl_state, protection, :scope, "scope is required and has no global fallback")

      is_nil(protection.key) ->
        error(dsl_state, protection, :key, "key is required")

      true ->
        :ok
    end
  end

  defp verify_data_layer(protection, dsl_state) do
    if Ash.DataLayer.data_layer(dsl_state) == AshPostgres.DataLayer do
      :ok
    else
      error(dsl_state, protection, :action, "protected actions require AshPostgres.DataLayer")
    end
  end

  defp verify_action_shape(protection, %{action: nil, dsl_state: dsl_state}) do
    error(
      dsl_state,
      protection,
      :action,
      "protected action #{inspect(protection.action)} does not exist"
    )
  end

  defp verify_action_shape(protection, %{action: %{type: :read}, dsl_state: dsl_state}) do
    error(dsl_state, protection, :action, "read actions cannot be protected")
  end

  defp verify_action_shape(protection, %{action: action, dsl_state: dsl_state}) do
    cond do
      Map.get(action, :transaction?) != true ->
        error(dsl_state, protection, :action, "protected action must set transaction? true")

      action.type == :action and not wrappable_run?(action.run) ->
        error(
          dsl_state,
          protection,
          :action,
          "generic action run must be a module-based implementation"
        )

      true ->
        :ok
    end
  end

  defp wrappable_run?({module, opts}) when is_atom(module) and is_list(opts) do
    module not in [Ash.Resource.Action.ImplementationFunction, Reactor]
  end

  defp wrappable_run?(_run), do: false

  defp verify_reserved_inputs(protection, context) do
    argument_names = Enum.map(context.action.arguments, & &1.name)
    accepted_names = List.wrap(Map.get(context.action, :accept))
    reserved = Enum.filter(@reserved_inputs, &(&1 in argument_names or &1 in accepted_names))

    if reserved == [] do
      :ok
    else
      error(
        context.dsl_state,
        protection,
        :action,
        "protected action exposes reserved verification inputs: #{inspect(reserved)}"
      )
    end
  end

  defp normalize_scope(protection, context) do
    case Scope.normalize(protection.scope) do
      {:ok, scope} ->
        with :ok <- verify_references(Scope.references(scope), protection, context, :scope) do
          {:ok, scope}
        end

      {:error, message} ->
        error(context.dsl_state, protection, :scope, message)
    end
  end

  defp verify_scope_bound(scope, limits, protection, dsl_state) do
    maximum = Keyword.fetch!(limits, :max_scope_components)

    if length(scope) <= maximum do
      :ok
    else
      error(
        dsl_state,
        protection,
        :scope,
        "scope has #{length(scope)} components but max_scope_components is #{maximum}"
      )
    end
  end

  defp normalize_key(protection, context) do
    case KeySource.normalize(protection.key) do
      {:ok, key} ->
        with :ok <- verify_references(KeySource.references(key), protection, context, :key) do
          {:ok, key}
        end

      {:error, message} ->
        error(context.dsl_state, protection, :key, message)
    end
  end

  # mutation sentinel: declared-reference-guard
  defp verify_references(references, protection, context, option),
    do: verify_reference_details(references, protection, context, option)

  defp verify_reference_details(references, protection, context, option) do
    arguments = MapSet.new(context.action.arguments, & &1.name)
    attributes = MapSet.new(context.attributes, & &1.name)
    missing_arguments = Enum.reject(references.arguments, &MapSet.member?(arguments, &1))
    missing_attributes = Enum.reject(references.attributes, &MapSet.member?(attributes, &1))

    cond do
      context.action.type == :action and references.attributes != [] ->
        error(
          context.dsl_state,
          protection,
          option,
          "generic actions cannot reference attributes"
        )

      missing_arguments == [] and missing_attributes == [] ->
        :ok

      true ->
        error(
          context.dsl_state,
          protection,
          option,
          "references missing arguments #{inspect(missing_arguments)} or attributes #{inspect(missing_attributes)}"
        )
    end
  end

  defp verify_scope_callbacks(protection, scope, dsl_state) do
    Enum.reduce_while(scope, :ok, fn
      {:tenant, module}, :ok ->
        case ensure_callbacks(module, resolve: 2) do
          :ok -> {:cont, :ok}
          {:error, message} -> {:halt, error(dsl_state, protection, :scope, message)}
        end

      _component, :ok ->
        {:cont, :ok}
    end)
  end

  defp verify_key_callbacks(protection, key, dsl_state) do
    Enum.reduce_while(key, :ok, fn
      {:verified, _argument, module}, :ok ->
        verify_trusted_module(module, [verify: 2], protection, dsl_state)

      {:minted, module}, :ok ->
        verify_trusted_module(module, [mint: 1], protection, dsl_state)

      _source, :ok ->
        {:cont, :ok}
    end)
  end

  defp verify_trusted_module(module, callback, protection, dsl_state) do
    case ensure_callbacks(module, callback ++ [algorithm: 0, trust_model: 0]) do
      :ok ->
        with {:ok, algorithm} <- invoke_declaration(module, :algorithm),
             {:ok, trust_model} <- invoke_declaration(module, :trust_model),
             true <- algorithm in [:hmac_sha256, :ed25519],
             true <- trust_model in [:same_service, :separated],
             false <- algorithm == :hmac_sha256 and trust_model == :separated do
          {:cont, :ok}
        else
          _invalid ->
            {:halt,
             error(
               dsl_state,
               protection,
               :key,
               "trusted key module has an invalid algorithm/trust model; separated HMAC is forbidden"
             )}
        end

      {:error, message} ->
        {:halt, error(dsl_state, protection, :key, message)}
    end
  end

  defp verify_strategy(%Protection{strategy: :idempotency} = protection, context),
    do: verify_idempotency(protection, context)

  defp verify_strategy(%Protection{strategy: :one_time_nonce} = protection, context),
    do: verify_nonce(protection, context)

  # mutation sentinel: idempotency-strategy-guard
  defp verify_idempotency(protection, context),
    do: verify_idempotency_details(protection, context)

  defp verify_idempotency_details(protection, context) do
    with {:ok, fingerprint} <- normalize_fingerprint(protection, context),
         :ok <- verify_response(protection, context),
         {:ok, retention} <-
           positive_duration(protection.retention, protection, context, :retention),
         :ok <-
           reject_present(protection.window, protection, context, :window, "window is nonce-only"),
         :ok <- verify_external_effect(protection, context) do
      {:ok, %{protection | fingerprint: fingerprint, retention: retention, window: nil}}
    end
  end

  # mutation sentinel: nonce-strategy-guard
  defp verify_nonce(protection, context), do: verify_nonce_details(protection, context)

  defp verify_nonce_details(protection, context) do
    with :ok <- verify_nonce_key(protection, context),
         :ok <-
           reject_present(
             protection.response,
             protection,
             context,
             :response,
             "nonce has no stored-response surface"
           ),
         :ok <-
           reject_present(
             protection.fingerprint,
             protection,
             context,
             :fingerprint,
             "nonce has no fingerprint surface"
           ),
         :ok <-
           reject_present(
             protection.retention,
             protection,
             context,
             :retention,
             "nonce retention derives from its window"
           ),
         :ok <-
           reject_present(
             protection.external_effect,
             protection,
             context,
             :external_effect,
             "nonce cannot configure external effects"
           ),
         :ok <- reject_explicit_failure_option(protection, context),
         {:ok, window} <- normalize_window(protection, context) do
      {:ok, %{protection | window: window, retention: nil, fingerprint: nil, response: nil}}
    end
  end

  # mutation sentinel: trusted-nonce-key-guard
  defp verify_nonce_key(protection, context), do: verify_nonce_key_details(protection, context)

  defp verify_nonce_key_details(protection, context) do
    cond do
      not Enum.all?(protection.key, fn source ->
        match?({:verified, _, _}, source) or match?({:minted, _}, source)
      end) ->
        error(
          context.dsl_state,
          protection,
          :key,
          "nonce keys must contain only verified or minted trusted sources"
        )

      length(protection.key) > 1 and Enum.any?(protection.key, &match?({:minted, _}, &1)) ->
        error(
          context.dsl_state,
          protection,
          :key,
          "a minted nonce key must be the only key source"
        )

      true ->
        :ok
    end
  end

  defp normalize_fingerprint(protection, context) do
    fingerprint = protection.fingerprint

    with :ok <- verify_fingerprint_shape(fingerprint, protection, context),
         arguments = Keyword.get(fingerprint, :arguments, []),
         attributes = Keyword.get(fingerprint, :attributes, []),
         :ok <- verify_fingerprint_values(arguments, attributes, protection, context),
         :ok <-
           verify_references(
             %{arguments: arguments, attributes: attributes},
             protection,
             context,
             :fingerprint
           ) do
      {:ok, [arguments: arguments, attributes: attributes]}
    end
  end

  defp verify_fingerprint_shape(fingerprint, protection, context) do
    cond do
      not is_list(fingerprint) ->
        error(context.dsl_state, protection, :fingerprint, "idempotency requires a fingerprint")

      Keyword.keys(fingerprint) -- [:arguments, :attributes] != [] ->
        error(context.dsl_state, protection, :fingerprint, "fingerprint has unknown options")

      true ->
        :ok
    end
  end

  defp verify_fingerprint_values(arguments, attributes, protection, context) do
    cond do
      not is_list(arguments) or not is_list(attributes) ->
        error(
          context.dsl_state,
          protection,
          :fingerprint,
          "fingerprint references must be lists"
        )

      arguments ++ attributes == [] ->
        error(
          context.dsl_state,
          protection,
          :fingerprint,
          "fingerprint must declare at least one input"
        )

      not Enum.all?(arguments ++ attributes, &is_atom/1) ->
        error(
          context.dsl_state,
          protection,
          :fingerprint,
          "fingerprint references must be atoms"
        )

      true ->
        :ok
    end
  end

  defp verify_response(%{response: %Response{} = response} = protection, context) do
    opts = response.opts
    fields = if Keyword.keyword?(opts), do: Keyword.get(opts, :fields, []), else: :invalid
    classifier = if Keyword.keyword?(opts), do: Keyword.get(opts, :classify), else: nil

    with true <- Keyword.keyword?(opts),
         true <- is_list(fields) and Enum.all?(fields, &is_atom/1),
         true <- is_atom(classifier) and not is_nil(classifier),
         :ok <- verify_response_fields(fields, context),
         :ok <- verify_response_codec(response.codec),
         :ok <- ensure_callbacks(classifier, classify: 2) do
      :ok
    else
      false when not is_list(fields) ->
        error(context.dsl_state, protection, :response, "response fields must be a list of atoms")

      false ->
        response_shape_error(protection, context, classifier, fields)

      {:error, message} ->
        error(context.dsl_state, protection, :response, message)

      {:field_error, message} ->
        error(context.dsl_state, protection, :response, message)
    end
  end

  defp verify_response(protection, context) do
    error(context.dsl_state, protection, :response, "idempotency requires response configuration")
  end

  defp verify_response_codec(codec) do
    with :ok <- ensure_callbacks(codec, format_tag: 0, encode: 3, decode: 4),
         {:ok, tag} <- invoke_declaration(codec, :format_tag),
         :ok <- AshOnetime.Codec.validate_tag(tag) do
      :ok
    else
      {:error, %AshOnetime.Error{}} ->
        {:error, "#{inspect(codec)} returned an invalid format tag"}

      :error ->
        {:error, "#{inspect(codec)} format_tag/0 failed"}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp response_shape_error(protection, context, classifier, fields) do
    cond do
      not is_list(fields) or not Enum.all?(fields, &is_atom/1) ->
        error(context.dsl_state, protection, :response, "response fields must be a list of atoms")

      not is_atom(classifier) or is_nil(classifier) ->
        error(context.dsl_state, protection, :response, "response classify module is required")

      true ->
        error(context.dsl_state, protection, :response, "response fields are invalid")
    end
  end

  defp verify_response_fields([], %{action: %{type: :action}}), do: :ok

  defp verify_response_fields(_fields, %{action: %{type: :action}}),
    do: {:field_error, "generic action response fields must be empty"}

  defp verify_response_fields(fields, context) do
    reserved = Ash.Resource.reserved_names()

    cond do
      fields != Enum.uniq(fields) ->
        {:field_error, "response fields must not contain duplicates"}

      Enum.any?(fields, &(&1 in reserved)) ->
        {:field_error, "response fields must not contain reserved names"}

      invalid = Enum.find(fields, &(not valid_response_attribute?(&1, context))) ->
        {:field_error,
         "response field #{inspect(invalid)} must be a public non-sensitive attribute"}

      true ->
        :ok
    end
  end

  defp valid_response_attribute?(field, context) do
    case ResourceInfo.attribute(context.dsl_state, field) do
      %{public?: true, sensitive?: false} -> true
      _other -> false
    end
  end

  defp verify_external_effect(%{external_effect: nil}, _context), do: :ok

  defp verify_external_effect(protection, context) do
    with :ok <- ensure_callbacks(protection.external_effect, execute: 3, recover: 3),
         :ok <- reject_external_untracked(protection, context) do
      :ok
    else
      {:error, %DslError{} = error} -> {:error, error}
      {:error, message} -> error(context.dsl_state, protection, :external_effect, message)
    end
  end

  defp reject_external_untracked(
         %{on_definite_store_failure: :execute_untracked} = protection,
         context
       ) do
    error(
      context.dsl_state,
      protection,
      :on_definite_store_failure,
      "external effects require a committed recovery point and cannot execute untracked"
    )
  end

  defp reject_external_untracked(_protection, _context), do: :ok

  defp reject_explicit_failure_option(protection, context) do
    if Entity.property_anno(protection, :on_definite_store_failure) do
      error(
        context.dsl_state,
        protection,
        :on_definite_store_failure,
        "nonce failure direction is fixed to fail closed and cannot be configured"
      )
    else
      :ok
    end
  end

  defp normalize_window(protection, context) do
    window = protection.window

    with true <- is_list(window),
         true <- Keyword.keys(window) -- [:max_age, :clock_skew] == [],
         {:ok, max_age} <- duration(Keyword.get(window, :max_age)),
         {:ok, clock_skew} <- duration(Keyword.get(window, :clock_skew)),
         true <- max_age + clock_skew <= @max_seconds do
      {:ok, [max_age: max_age, clock_skew: clock_skew]}
    else
      _invalid ->
        error(
          context.dsl_state,
          protection,
          :window,
          "nonce window requires bounded nonnegative max_age and clock_skew"
        )
    end
  end

  defp positive_duration(value, protection, context, option) do
    case duration(value) do
      {:ok, seconds} when seconds > 0 ->
        {:ok, seconds}

      _invalid ->
        error(context.dsl_state, protection, option, "must be a positive bounded duration")
    end
  end

  defp duration(seconds) when is_integer(seconds) and seconds >= 0 and seconds <= @max_seconds,
    do: {:ok, seconds}

  defp duration({amount, unit}) when is_integer(amount) and amount >= 0 do
    case Keyword.fetch(@duration_factors, unit) do
      {:ok, factor} when amount <= div(@max_seconds, factor) -> {:ok, amount * factor}
      _invalid -> :error
    end
  end

  defp duration(_value), do: :error

  defp normalize_limits(protection, dsl_state) do
    limits = protection.limits
    unknown = Keyword.keys(limits) -- Keyword.keys(@limit_ceilings)

    cond do
      not Keyword.keyword?(limits) ->
        error(dsl_state, protection, :limits, "limits must be a keyword list")

      unknown != [] ->
        error(dsl_state, protection, :limits, "unknown limit options: #{inspect(unknown)}")

      Enum.any?(limits, fn {key, value} ->
        not is_integer(value) or value <= 0 or value > Keyword.fetch!(@limit_ceilings, key)
      end) ->
        error(
          dsl_state,
          protection,
          :limits,
          "limit overrides must be positive and cannot exceed package ceilings"
        )

      true ->
        {:ok, Keyword.merge(@limit_ceilings, limits)}
    end
  end

  defp verify_lifecycle(
         %{strategy: :one_time_nonce} = protection,
         %{action: %{type: type}} = context
       )
       when type in [:create, :update, :destroy],
       do: verify_nonce_crud_lifecycle(protection, context)

  defp verify_lifecycle(%{strategy: :one_time_nonce} = protection, context),
    do: verify_no_notifiers(protection, context)

  # mutation sentinel: idempotency-lifecycle-guard
  defp verify_lifecycle(protection, context), do: verify_lifecycle_details(protection, context)

  defp verify_lifecycle_details(protection, context) do
    callbacks =
      if context.action.type == :action do
        ResourceInfo.preparations(context.dsl_state, :action) ++ context.action.preparations
      else
        ResourceInfo.validations(context.dsl_state, context.action.type) ++
          lifecycle_changes(context.dsl_state, context.action)
      end

    case verify_no_notifiers(protection, context) do
      :ok -> verify_lifecycle_callbacks(callbacks, protection, context.dsl_state)
      error -> error
    end
  end

  defp verify_nonce_crud_lifecycle(protection, context) do
    callbacks = lifecycle_changes(context.dsl_state, context.action)

    case verify_no_notifiers(protection, context) do
      :ok -> verify_nonce_around_callbacks(callbacks, protection, context.dsl_state)
      error -> error
    end
  end

  defp lifecycle_changes(dsl_state, action) do
    ResourceInfo.changes(dsl_state, action.type) ++ action.changes
  end

  defp verify_nonce_around_callbacks(callbacks, protection, dsl_state) do
    Enum.reduce_while(callbacks, :ok, fn callback, :ok ->
      case verify_nonce_around_callback(callback) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, error(dsl_state, protection, :action, message)}
      end
    end)
  end

  defp verify_nonce_around_callback(%Ash.Resource.Change{change: {module, opts}})
       when module in @nonce_non_around_changes and is_list(opts),
       do: :ok

  defp verify_nonce_around_callback(%Ash.Resource.Change{
         change: {Ash.Resource.Change.DebugLog, _opts}
       }),
       do: {:error, "Ash.Resource.Change.DebugLog declares an additional around-action boundary"}

  defp verify_nonce_around_callback(%Ash.Resource.Change{
         change: {Ash.Resource.Change.Function, _opts}
       }),
       do: {:error, "inline lifecycle callbacks cannot prove the sole around-action boundary"}

  defp verify_nonce_around_callback(%Ash.Resource.Change{change: {module, opts}})
       when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :replay_capabilities, 1) do
      with {:ok, capabilities} <- invoke_declaration(module, :replay_capabilities, [opts]),
           :ok <- validate_nonce_around_capabilities(capabilities) do
        :ok
      else
        {:error, message} when is_binary(message) -> {:error, "#{inspect(module)} #{message}"}
        _invalid -> {:error, "#{inspect(module)} returned an invalid capability declaration"}
      end
    else
      {:error,
       "#{inspect(module)} must export replay_capabilities/1 to prove it adds no around-action boundary"}
    end
  end

  defp verify_nonce_around_callback(_callback),
    do: {:error, "lifecycle callback cannot prove the sole around-action boundary"}

  defp validate_nonce_around_capabilities(
         %{
           notifications: _notifications,
           effects: _effects,
           around_action: false,
           marker: _marker
         } = capabilities
       )
       when map_size(capabilities) == 4,
       do: :ok

  defp validate_nonce_around_capabilities(%{around_action: true}),
    do: {:error, "declares an additional around-action boundary"}

  defp validate_nonce_around_capabilities(_capabilities),
    do: {:error, "must declare a closed around-action capability"}

  defp verify_lifecycle_callbacks(callbacks, protection, dsl_state) do
    Enum.reduce_while(callbacks, :ok, fn callback, :ok ->
      case verify_replay_callback(callback) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, error(dsl_state, protection, :action, message)}
      end
    end)
  end

  defp verify_no_notifiers(protection, %{action: %{type: type}} = context)
       when type in [:create, :update, :destroy] do
    notifiers = ResourceInfo.notifiers(context.dsl_state) ++ context.action.notifiers

    if notifiers == [] do
      :ok
    else
      error(
        context.dsl_state,
        protection,
        :action,
        "notifier delivery is unsupported for protected CRUD actions"
      )
    end
  end

  defp verify_no_notifiers(_protection, _context), do: :ok

  defp verify_replay_callback(%Ash.Resource.Change{
         change: {Ash.Resource.Change.ManageRelationship, _opts}
       }),
       do: {:error, "managed relationships are unsafe for idempotent replay"}

  defp verify_replay_callback(%Ash.Resource.Change{
         change: {Ash.Resource.Change.RelateActor, _opts}
       }),
       do: {:error, "relating the actor is unsafe for idempotent replay"}

  defp verify_replay_callback(%Ash.Resource.Change{change: ref}),
    do: verify_replay_ref(ref, @replay_safe_changes)

  defp verify_replay_callback(%Ash.Resource.Preparation{preparation: ref}),
    do: verify_replay_ref(ref, @replay_safe_preparations)

  defp verify_replay_callback(%Ash.Resource.Validation{} = validation),
    do: verify_replay_validation(validation)

  defp verify_replay_callback(_callback), do: {:error, "unsupported lifecycle callback shape"}

  # mutation sentinel: replay-callback-guard
  defp verify_replay_ref(ref, allowlist), do: verify_replay_ref_details(ref, allowlist)

  defp verify_replay_ref_details({Ash.Resource.Change.SetAttribute, opts}, _allowlist)
       when is_list(opts),
       do: verify_literal_builtin(opts[:value], "set_attribute value")

  defp verify_replay_ref_details({Ash.Resource.Change.SetContext, opts}, _allowlist)
       when is_list(opts),
       do: verify_literal_builtin(opts[:context], "set_context context")

  defp verify_replay_ref_details({Ash.Resource.Preparation.SetContext, opts}, _allowlist)
       when is_list(opts),
       do: verify_literal_builtin(opts[:context], "set_context context")

  defp verify_replay_ref_details({module, opts}, _allowlist)
       when module in [Ash.Resource.Change.Function, Ash.Resource.Preparation.Function] and
              is_list(opts),
       do: {:error, "inline lifecycle callbacks cannot declare replay safety"}

  defp verify_replay_ref_details({module, opts}, allowlist)
       when is_atom(module) and is_list(opts) do
    if module in allowlist,
      do: :ok,
      else: verify_custom_lifecycle(module, opts, "")
  end

  defp verify_replay_ref_details(_ref, _allowlist),
    do: {:error, "lifecycle callback is not module-based"}

  defp verify_custom_lifecycle(module, opts, suffix) do
    if Code.ensure_loaded?(module) and function_exported?(module, :replay_safety, 1) do
      case invoke_declaration(module, :replay_safety, [opts]) do
        {:ok, mode} when mode in [:pure, :replay_aware] ->
          verify_custom_capabilities(module, opts, mode)

        _invalid ->
          {:error, "#{inspect(module)} returned an invalid replay safety declaration"}
      end
    else
      {:error, "#{inspect(module)} must export replay_safety/1#{suffix}"}
    end
  end

  defp verify_custom_capabilities(module, opts, mode) do
    if function_exported?(module, :replay_capabilities, 1) do
      with {:ok, capabilities} <- invoke_declaration(module, :replay_capabilities, [opts]),
           :ok <- validate_replay_capabilities(mode, capabilities) do
        :ok
      else
        {:error, message} when is_binary(message) ->
          {:error, "#{inspect(module)} #{message}"}

        _invalid ->
          {:error, "#{inspect(module)} returned an invalid replay capability declaration"}
      end
    else
      {:error, "#{inspect(module)} must export replay_capabilities/1"}
    end
  end

  defp validate_replay_capabilities(
         :pure,
         %{notifications: false, effects: false, around_action: false, marker: :unused} =
           capabilities
       )
       when map_size(capabilities) == 4,
       do: :ok

  defp validate_replay_capabilities(
         :replay_aware,
         %{
           notifications: notifications,
           effects: effects,
           around_action: false,
           marker: :consumed
         } =
           capabilities
       )
       when is_boolean(notifications) and is_boolean(effects) and map_size(capabilities) == 4,
       do: :ok

  defp validate_replay_capabilities(_mode, %{around_action: true}),
    do: {:error, "declares an additional around-action boundary"}

  defp validate_replay_capabilities(:pure, _capabilities),
    do: {:error, "declares notification/effect capabilities incompatible with :pure"}

  defp validate_replay_capabilities(:replay_aware, _capabilities),
    do: {:error, "must consume the replay marker and declare closed capabilities"}

  defp verify_literal_builtin(value, label) do
    if is_function(value) or
         match?(
           {module, function, args} when is_atom(module) and is_atom(function) and is_list(args),
           value
         ) do
      {:error, "#{label} must be literal for idempotent replay"}
    else
      :ok
    end
  end

  # mutation sentinel: replay-validation-guard
  defp verify_replay_validation(validation), do: verify_replay_validation_details(validation)

  defp verify_replay_validation_details(%Ash.Resource.Validation{
         validation: validation,
         where: where
       }) do
    with :ok <- verify_validation_ref(validation), do: verify_validation_refs(where)
  end

  defp verify_validation_refs(refs) when is_list(refs) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case verify_validation_ref(ref) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp verify_validation_refs(_refs),
    do: {:error, "validation conditions must be module-based for idempotent replay"}

  defp verify_validation_ref({Ash.Resource.Validation.Function, _opts}),
    do: {:error, "inline validation functions are unsafe for idempotent replay"}

  defp verify_validation_ref({module, opts})
       when module in [Ash.Resource.Validation.All, Ash.Resource.Validation.Any] and is_list(opts) do
    case Keyword.fetch(opts, :validations) do
      {:ok, validations} -> verify_validation_refs(validations)
      :error -> {:error, "composed validation must declare its validations"}
    end
  end

  defp verify_validation_ref({Ash.Resource.Validation.Negate, opts}) when is_list(opts) do
    case Keyword.fetch(opts, :validation) do
      {:ok, validation} -> verify_validation_ref(validation)
      :error -> {:error, "negated validation must declare its validation"}
    end
  end

  defp verify_validation_ref({Ash.Resource.Validation.Compare, opts}) when is_list(opts) do
    executable =
      Enum.find(@comparison_options, fn option ->
        opts |> Keyword.get(option) |> is_function()
      end)

    if executable do
      {:error, "compare validation option #{inspect(executable)} must be literal"}
    else
      :ok
    end
  end

  defp verify_validation_ref({Ash.Resource.Validation.Match, opts}) when is_list(opts) do
    case Keyword.get(opts, :match) do
      {Spark.Regex, :cache, [pattern, flags]}
      when is_binary(pattern) and (is_binary(flags) or is_list(flags)) ->
        :ok

      %Regex{} ->
        :ok

      _other ->
        {:error, "match validation must use Ash's deterministic regex provider"}
    end
  end

  defp verify_validation_ref({module, opts})
       when module in @replay_safe_validations and is_list(opts),
       do: :ok

  defp verify_validation_ref({module, opts}) when is_atom(module) and is_list(opts) do
    verify_custom_lifecycle(module, opts, " for idempotent replay validation")
  end

  defp verify_validation_ref(module) when is_atom(module), do: verify_validation_ref({module, []})

  defp verify_validation_ref(_ref),
    do: {:error, "validation must be module-based for idempotent replay"}

  defp inject_all(dsl_state, protections) do
    Enum.reduce_while(protections, {:ok, dsl_state}, fn protection, {:ok, state} ->
      action = ResourceInfo.action(state, protection.action)

      case inject(state, action, protection) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp inject(dsl_state, %{type: :action} = action, protection) do
    if match?({AshOnetime.GenericAction, _opts}, action.run) or
         Enum.any?(action.preparations, &package_preparation?/1) do
      error(dsl_state, protection, :action, "AshOnetime generic wrapper is already present")
    else
      package_preparation = %Ash.Resource.Preparation{
        preparation: {AshOnetime.GenericAction, [protection: protection]},
        on: [:action],
        only_when_valid?: false,
        where: []
      }

      replacement = %{
        action
        | run: {AshOnetime.GenericAction, [protection: protection, original: action.run]},
          preparations: action.preparations ++ [package_preparation]
      }

      {:ok, replace_action(dsl_state, action, replacement)}
    end
  end

  defp inject(dsl_state, action, protection) do
    if Enum.any?(action.changes, &package_change?/1) do
      error(dsl_state, protection, :action, "AshOnetime change wrapper is already present")
    else
      wrapper = %Ash.Resource.Change{
        change: {AshOnetime.Change, [protection: protection]},
        on: [action.type],
        only_when_valid?: false,
        always_atomic?: false,
        where: []
      }

      replacement = %{action | changes: [wrapper | action.changes]}
      {:ok, replace_action(dsl_state, action, replacement)}
    end
  end

  defp replace_action(dsl_state, action, replacement) do
    Transformer.replace_entity(
      dsl_state,
      [:actions],
      replacement,
      &(&1.name == action.name and &1.type == action.type)
    )
  end

  defp package_change?(%Ash.Resource.Change{change: {AshOnetime.Change, _opts}}), do: true
  defp package_change?(_change), do: false

  defp package_preparation?(%Ash.Resource.Preparation{
         preparation: {AshOnetime.GenericAction, _opts}
       }),
       do: true

  defp package_preparation?(_preparation), do: false

  defp ensure_callbacks(module, callbacks) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        missing_callbacks(module, callbacks)

      _error ->
        {:error, "#{inspect(module)} is not compiled"}
    end
  end

  defp ensure_callbacks(module, _callbacks), do: {:error, "#{inspect(module)} is not a module"}

  defp missing_callbacks(module, callbacks) do
    missing =
      Enum.reject(callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)

    if missing == [] do
      :ok
    else
      {:error, "#{inspect(module)} is missing callbacks #{inspect(missing)}"}
    end
  end

  defp invoke_declaration(module, name, args \\ []) do
    {:ok, apply(module, name, args)}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp reject_present(nil, _protection, _context, _option, _message), do: :ok

  defp reject_present(_value, protection, context, option, message),
    do: error(context.dsl_state, protection, option, message)

  defp error(dsl_state, protection, option, message) do
    {:error,
     DslError.exception(
       module: Transformer.get_persisted(dsl_state, :module),
       path: [:onetime, :protect, protection.action, option],
       location: Entity.property_anno(protection, option) || Entity.anno(protection),
       message: message
     )}
  end
end
