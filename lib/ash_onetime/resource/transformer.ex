defmodule AshOnetime.Resource.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshOnetime.Codec
  alias AshOnetime.KeySource
  alias AshOnetime.Resource.Protection
  alias AshOnetime.Resource.Response
  alias AshOnetime.Scope
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @max_seconds 2_147_483_647
  @duration_factors [second: 1, minute: 60, hour: 3_600, day: 86_400]
  # The full limit vocabulary (11 keys) is the union of the protect-only ceilings (key/
  # verification/cache paths) and the response-structural ceilings (max_response_*, sourced
  # from Codec.hard_limits/0). Both halves are owned by Codec so there is a single source of
  # truth (ARCH-8 union collapse) — the transformer reads them for compile-time validation.
  @limit_ceilings Keyword.merge(Codec.protect_only_ceilings(), Keyword.new(Codec.hard_limits()))
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
         :ok <- verify_tenant_scope(scope, protection, context),
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
    reserved_inputs = AshOnetime.reserved_verification_inputs()
    argument_names = Enum.map(context.action.arguments, & &1.name)
    accepted_names = List.wrap(Map.get(context.action, :accept))
    attribute_names = Enum.map(ResourceInfo.attributes(context.dsl_state), & &1.name)

    reserved_via_inputs =
      Enum.filter(reserved_inputs, &(&1 in argument_names or &1 in accepted_names))

    # A protected resource that DECLARES an attribute with a reserved name would let a
    # caller set a trusted-local fact via the changeset attribute surface even with no
    # action argument or `accept` entry (the runtime guard `Admission.reject_reserved/1`
    # checks `changeset.attributes`). Reject it at compile time to match the runtime guard.
    reserved_via_attributes =
      Enum.filter(reserved_inputs, &(&1 in attribute_names and &1 not in accepted_names))

    cond do
      reserved_via_inputs != [] ->
        error(
          context.dsl_state,
          protection,
          :action,
          "protected action exposes reserved verification inputs: #{inspect(reserved_via_inputs)}"
        )

      reserved_via_attributes != [] ->
        error(
          context.dsl_state,
          protection,
          :action,
          "protected resource declares a reserved verification attribute: #{inspect(reserved_via_attributes)}"
        )

      true ->
        :ok
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

  # mutation sentinel: attribute-tenant-scope-guard
  defp verify_tenant_scope(scope, protection, context),
    do: verify_tenant_scope_details(scope, protection, context)

  # Attribute multitenancy shares one physical set of claim tables across tenants (the
  # resource's own schema), so cross-tenant isolation depends entirely on the tenant
  # discriminator being present in the declared scope. Require it, or a tenant resolver.
  defp verify_tenant_scope_details(scope, protection, %{dsl_state: dsl_state}) do
    case ResourceInfo.multitenancy_strategy(dsl_state) do
      :attribute ->
        tenant_attribute = ResourceInfo.multitenancy_attribute(dsl_state)

        if tenant_scoped?(scope, tenant_attribute) do
          :ok
        else
          error(dsl_state, protection, :scope, tenant_scope_message(tenant_attribute))
        end

      _strategy ->
        :ok
    end
  end

  defp tenant_scoped?(scope, tenant_attribute) do
    Enum.any?(scope, fn
      {:tenant, _module} -> true
      {:attribute, attribute} -> not is_nil(tenant_attribute) and attribute == tenant_attribute
      _component -> false
    end)
  end

  defp tenant_scope_message(tenant_attribute) do
    "attribute multitenancy requires the tenant attribute #{inspect(tenant_attribute)} " <>
      "or a {:tenant, module} resolver in scope"
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
         :ok <- reject_explicit_commit(protection, context),
         :ok <- verify_external_effect(protection, context) do
      {:ok, %{protection | fingerprint: fingerprint, retention: retention, window: nil}}
    end
  end

  # mutation sentinel: idempotency-rejects-commit-guard
  defp reject_explicit_commit(protection, context) do
    if Entity.property_anno(protection, :commit) do
      error(
        context.dsl_state,
        protection,
        :commit,
        "commit is nonce-only; idempotency commits with its effect and cannot be configured"
      )
    else
      :ok
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
    fields = response.fields
    classifier = response.classify

    with true <- is_list(fields) and Enum.all?(fields, &is_atom/1),
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
    # Code.ensure_compiled/1 triggers the module's compilation if it has not run yet
    # (needed: callback modules — resolvers, codecs, verifiers — are often defined in the
    # same compile unit as the protected resource and not yet compiled when this
    # transformer runs). The cycle hazard (L10) is when the callback module transitively
    # depends on the protected resource itself: ensure_compiled returns
    # {:error, :nofile | :unavailable | :module_unavailable}, and the cycle case surfaces
    # as the opaque "is not compiled" message. Distinguish the cycle/unavailable case
    # (give the ordering guidance) from the genuine missing-module case, and only THEN
    # check the callbacks are exported.
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        verify_exported_callbacks(module, callbacks)

      {:error, reason} when reason in [:unavailable, :module_unavailable] ->
        # A compile cycle: the callback module is being compiled RIGHT NOW (it
        # transitively depends on this resource). It must be compiled BEFORE the resource
        # that protects an action it serves — move it to an earlier-compiled module.
        {:error,
         "#{inspect(module)} cannot be compiled while the protected resource is compiling " <>
           "(#{inspect(reason)}); it must be compiled before the resource that protects an " <>
           "action it serves — ensure it does not depend on the protected resource"}

      _missing ->
        {:error, "#{inspect(module)} is not a compiled module"}
    end
  end

  defp ensure_callbacks(module, _callbacks), do: {:error, "#{inspect(module)} is not a module"}

  defp missing_callbacks_message(module, missing),
    do: "#{inspect(module)} is missing callbacks #{inspect(missing)}"

  defp verify_exported_callbacks(module, callbacks) do
    missing =
      Enum.reject(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)

    if missing == [], do: :ok, else: {:error, missing_callbacks_message(module, missing)}
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
