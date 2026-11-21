defmodule AshOnetime.DeliveryComparatorControls do
  @moduledoc false

  @rows [
    %{
      id: :pc_o4_completion_deadline_expression,
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "response_retain_until = statement_timestamp() + COALESCE($11::bigint, $10::bigint, extract(epoch FROM (response_retain_until - admitted_at))) * interval '1 second'",
      mutated:
        "response_retain_until = statement_timestamp() + COALESCE($11::bigint, $10::bigint, extract(epoch FROM (response_retain_until - admitted_at))) * interval '1 second' - interval '1 second'",
      action: :external_issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o4],
      opts: []
    },
    %{
      id: :pc_o4_outcome_clock_source,
      path: "test/support/exit_boundary/scenarios.ex",
      original: "SELECT claim_id, attempt, outcome, recorded_at, (to_jsonb(o)",
      mutated:
        "SELECT claim_id, attempt, outcome, recorded_at + interval '1 microsecond' AS recorded_at, (to_jsonb(o)",
      action: :external_issue,
      branch: :recovered,
      fault: nil,
      kind: :comparison,
      rules: [:o4],
      opts: []
    },
    %{
      id: :pc_o4_response_deadline_copy,
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      response_retain_until: response_retain_until,",
      mutated:
        "      response_retain_until: %{response_retain_until | second: rem(response_retain_until.second + 1, 60)},",
      action: :external_issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o4],
      opts: []
    },
    %{
      id: :pc_o2a_resource_run,
      path: "lib/ash_onetime/admission.ex",
      original: "      resource: inspect(subject.resource),\n      action: subject.action.name\n",
      mutated:
        "      resource: if(subject.resource == AshOnetime.Test.ExitBoundary.Withheld, do: inspect(AshOnetime.Test.ExitBoundary.Domain), else: inspect(subject.resource)),\n      action: subject.action.name\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2a_operation],
      opts: []
    },
    %{
      id: :pc_o2a_action_run,
      path: "lib/ash_onetime/admission.ex",
      original: "      resource: inspect(subject.resource),\n      action: subject.action.name\n",
      mutated:
        "      resource: inspect(subject.resource),\n      action: if(subject.resource == AshOnetime.Test.ExitBoundary.Withheld, do: :different_action, else: subject.action.name)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2a_operation],
      opts: []
    },
    %{
      id: :pc_o2a_resource_twin,
      path: "lib/ash_onetime/admission.ex",
      original: "      resource: inspect(subject.resource),\n      action: subject.action.name\n",
      mutated:
        "      resource: if(subject.resource == AshOnetime.Test.ExitBoundary.Returned, do: inspect(AshOnetime.Test.ExitBoundary.Domain), else: inspect(subject.resource)),\n      action: subject.action.name\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2a_operation],
      opts: []
    },
    %{
      id: :pc_o2a_action_twin,
      path: "lib/ash_onetime/admission.ex",
      original: "      resource: inspect(subject.resource),\n      action: subject.action.name\n",
      mutated:
        "      resource: inspect(subject.resource),\n      action: if(subject.resource == AshOnetime.Test.ExitBoundary.Returned, do: :different_action, else: subject.action.name)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2a_operation],
      opts: []
    },
    %{
      id: :pc_o2a_binding,
      path: "lib/ash_onetime/delivery.ex",
      original:
        "         context = Envelope.context(ref, inv, handle.resource, handle.action),\n",
      mutated:
        "         context = Envelope.context(ref, inv, handle.resource, :different_action),\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:envelope_binding],
      opts: []
    },
    %{
      id: :pc_o2b_protection_run,
      path: "lib/ash_onetime/change.ex",
      original:
        "      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      mutated:
        "      AshOnetime.Admission.dispatch_reservation(changeset, if(not is_nil(delivery), do: %{protection | executing_only: [:short]}, else: protection), trusted, delivery)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2b_protection],
      opts: []
    },
    %{
      id: :pc_o2b_protection_twin,
      path: "lib/ash_onetime/change.ex",
      original:
        "      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      mutated:
        "      AshOnetime.Admission.dispatch_reservation(changeset, if(is_nil(delivery), do: %{protection | executing_only: [:short]}, else: protection), trusted, delivery)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2b_protection],
      opts: []
    },
    %{
      id: :pc_host_arguments,
      path: "lib/ash_onetime/delivery.ex",
      original: "    case module.produce(subject, context) do\n",
      mutated:
        "    case module.produce(subject, Map.put(context, :extra, rem(byte_size(handle.ref), 2))) do\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:host_arguments],
      opts: []
    },
    %{
      id: :pc_complete_payload_nil,
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      Result.success(:complete, claim: completed, payload: encoded_response)\n",
      mutated:
        "      Result.success(:complete, claim: completed, payload: if(target.context_multitenant?, do: nil, else: encoded_response))\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:response_copy],
      opts: []
    },
    %{
      id: :pc_complete_codec_nil,
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      Result.success(:complete, claim: completed, payload: encoded_response)\n",
      mutated:
        "      completed = if target.context_multitenant?, do: %{completed | response_codec: nil}, else: completed\n      Result.success(:complete, claim: completed, payload: encoded_response)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:response_copy],
      opts: []
    },
    %{
      id: :pc_complete_digest_nil,
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      Result.success(:complete, claim: completed, payload: encoded_response)\n",
      mutated:
        "      completed = if target.context_multitenant?, do: %{completed | response_digest: nil}, else: completed\n      Result.success(:complete, claim: completed, payload: encoded_response)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:response_copy],
      opts: []
    },
    %{
      id: :pc_attribute_copy_run,
      path: "lib/ash_onetime/admission.ex",
      original: "        %Ash.Changeset{} ->\n          [subject.attributes | surfaces]\n",
      mutated:
        "        %Ash.Changeset{} -> [if(subject.resource == AshOnetime.Test.ExitBoundary.Withheld, do: Map.put(subject.attributes, :id, \"00000000-0000-4000-8000-000000000099\"), else: subject.attributes) | surfaces]\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:attribute_copy],
      opts: []
    },
    %{
      id: :pc_attribute_copy_twin,
      path: "lib/ash_onetime/admission.ex",
      original: "        %Ash.Changeset{} ->\n          [subject.attributes | surfaces]\n",
      mutated:
        "        %Ash.Changeset{} -> [if(subject.resource == AshOnetime.Test.ExitBoundary.Returned, do: Map.put(subject.attributes, :id, \"00000000-0000-4000-8000-000000000099\"), else: subject.attributes) | surfaces]\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:attribute_copy],
      opts: []
    },
    %{
      id: :pc_o2b_response_run,
      path: "lib/ash_onetime/admission.ex",
      original:
        "    Response.contract(subject.resource, subject.action.name, response, trusted)\n",
      mutated:
        "    Response.contract(subject.resource, subject.action.name, if(subject.resource == AshOnetime.Test.ExitBoundary.Withheld, do: %{response | codec_opts: [runtime_alteration: true]}, else: response), trusted)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2b_response],
      opts: []
    },
    %{
      id: :pc_o2b_response_twin,
      path: "lib/ash_onetime/admission.ex",
      original:
        "    Response.contract(subject.resource, subject.action.name, response, trusted)\n",
      mutated:
        "    Response.contract(subject.resource, subject.action.name, if(subject.resource == AshOnetime.Test.ExitBoundary.Returned, do: %{response | codec_opts: [runtime_alteration: true]}, else: response), trusted)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2b_response],
      opts: []
    },
    %{
      id: :pc_o2b_argument_run,
      path: "lib/ash_onetime/admission.ex",
      original: "           Enum.find(subject.action.arguments, &(&1.name == name)) do\n",
      mutated:
        "           Enum.find(if(subject.resource == AshOnetime.Test.ExitBoundary.Withheld, do: Enum.map(subject.action.arguments, &%{&1 | description: \"runtime alteration\"}), else: subject.action.arguments), &(&1.name == name)) do\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2b_argument],
      opts: []
    },
    %{
      id: :pc_o2b_argument_twin,
      path: "lib/ash_onetime/admission.ex",
      original: "           Enum.find(subject.action.arguments, &(&1.name == name)) do\n",
      mutated:
        "           Enum.find(if(subject.resource == AshOnetime.Test.ExitBoundary.Returned, do: Enum.map(subject.action.arguments, &%{&1 | description: \"runtime alteration\"}), else: subject.action.arguments), &(&1.name == name)) do\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2b_argument],
      opts: []
    },
    %{
      id: :pc_o2c_code,
      path: "lib/ash_onetime/change.ex",
      original:
        "    reservation =\n      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      mutated:
        "    changeset = if delivery do\n      replacement = change(%{changeset | around_action: []}, [protection: %{protection | executing_only: [], produce: nil}], context)\n      %{changeset | around_action: replacement.around_action}\n    else\n      changeset\n    end\n    reservation =\n      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2c_code, :o2c_environment],
      opts: []
    },
    %{
      id: :pc_o2c_environment,
      path: "lib/ash_onetime/change.ex",
      original:
        "    reservation =\n      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      mutated:
        "    changeset = if delivery do\n      replacement = change(%{changeset | around_action: []}, [protection: %{protection | executing_only: Enum.reverse(protection.executing_only)}], context)\n      %{changeset | around_action: replacement.around_action}\n    else\n      changeset\n    end\n    reservation =\n      AshOnetime.Admission.dispatch_reservation(changeset, protection, trusted, delivery)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o2c_code, :o2c_environment],
      opts: []
    },
    %{
      id: :pc_context_copy_ref,
      path: "lib/ash_onetime/generic_action.ex",
      original: "        run_original(input, Keyword.get(opts, :original), context)\n",
      mutated:
        "        context = if Map.has_key?(context.source_context.private, :ash_onetime_delivery) do\n          %{context | source_context: put_in(context.source_context, [:private, :ash_onetime_delivery, :ref], <<0::128>>)}\n        else\n          context\n        end\n        run_original(input, Keyword.get(opts, :original), context)\n",
      action: :mint,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:context_copy],
      opts: []
    },
    %{
      id: :pc_context_copy_cell,
      path: "lib/ash_onetime/generic_action.ex",
      original: "        run_original(input, Keyword.get(opts, :original), context)\n",
      mutated:
        "        context = if Map.has_key?(context.source_context.private, :ash_onetime_delivery) do\n          %{context | source_context: put_in(context.source_context, [:private, :ash_onetime_delivery_cell], context.source_context.private.ash_onetime_delivery.ref)}\n        else\n          context\n        end\n        run_original(input, Keyword.get(opts, :original), context)\n",
      action: :mint,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:context_copy],
      opts: []
    },
    %{
      id: :pc_context_copy_admitted,
      path: "lib/ash_onetime/generic_action.ex",
      original: "        run_original(input, Keyword.get(opts, :original), context)\n",
      mutated:
        "        context = if Map.has_key?(context.source_context.private, :ash_onetime_delivery) do\n          %{context | source_context: input.context}\n        else\n          context\n        end\n        run_original(input, Keyword.get(opts, :original), context)\n",
      action: :mint,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:context_copy],
      opts: []
    },
    %{
      id: :pc_o4_date_copy,
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      [partition_date, codec, digest] ++\n",
      mutated:
        "      [if(claim.operation_hash == COMPARATOR_DATE_OPERATION, do: Date.add(partition_date, 1), else: partition_date), codec, digest] ++\n",
      action: :external_issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o4, :o4_date_copy],
      opts: []
    },
    %{
      id: :pc_o5a_extra_frame,
      path: "lib/ash_onetime/delivery.ex",
      original:
        "  defp dispatch(%Ash.Changeset{action: %{type: :create}} = changeset, opts),\n    do: Ash.create(changeset, opts)\n",
      mutated:
        "  defp dispatch(%Ash.Changeset{action: %{type: :create}} = changeset, opts),\n    do: diagnostic_frame(changeset, opts)\n\n  defp diagnostic_frame(changeset, opts) do\n    try do\n      Ash.create(changeset, opts)\n    rescue\n      error -> reraise error, __STACKTRACE__\n    end\n  end\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :comparison,
      rules: [:o5a],
      opts: []
    },
    %{
      id: :pc_o5a_wrong_line,
      path: "test/support/exit_boundary/path_frames.ex",
      original:
        "      Map.put(slot, :frame, {module, function, arity, location(module, source)})\n",
      mutated:
        "      location = Keyword.update!(location(module, source), :line, &(&1 + 1))\n      Map.put(slot, :frame, {module, function, arity, location})\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :comparison,
      rules: [:o5a],
      opts: []
    },
    %{
      id: :pc_o5a_wrong_anchor,
      path: "test/support/exit_boundary/path_frames.ex",
      original:
        "      %{mfa: {Delivery, :armed, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n",
      mutated:
        "      %{mfa: {Delivery, :armed, 4}, anchor: {Ash.Actions.Update, :run, 4}, source: {:armed, 4, :dispatch, 2}},\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :comparison,
      rules: [:o5a],
      opts: []
    },
    %{
      id: :pc_u14_extra_expected_frame,
      path: "test/support/exit_boundary/path_frames.ex",
      original:
        "      %{mfa: {Delivery, :armed, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n",
      mutated:
        "      %{mfa: {Delivery, :armed, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n      %{mfa: {Delivery, :unexpected_frame, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :comparison,
      rules: [:o5a],
      opts: []
    },
    %{
      id: :pc_return_destroy,
      path: "lib/ash_onetime/delivery.ex",
      original: "      do: {:ok, nil, value},\n      else: {:ok, value}\n",
      mutated: "      do: {:ok, value},\n      else: {:ok, value}\n",
      action: :revoke,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:permitted_return],
      opts: [return_notifications?: true, return_destroyed?: false]
    },
    %{
      id: :pc_return_raw,
      path: "lib/ash_onetime/delivery.ex",
      original:
        "    subject\n    |> put_reference(ref)\n    |> dispatch(opts)\n    |> normalize(subject.action.type, opts)\n    |> finish(fn -> open(key, ref, secret, public, protection, resource, action) end)\n",
      mutated:
        "    raw = subject |> put_reference(ref) |> dispatch(opts)\n    raw = case raw do\n      {:ok, result} -> {:ok, result, []}\n      other -> other\n    end\n    raw\n    |> normalize(subject.action.type, opts)\n    |> finish(fn -> open(key, ref, secret, public, protection, resource, action) end)\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :comparison,
      rules: [:o5, :o5_list],
      opts: []
    },
    %{
      id: :pc_u13_undeclared_difference,
      path: "test/support/exit_boundary/resources.ex",
      original:
        "defmodule AshOnetime.Test.ExitBoundary.Returned do\n  @moduledoc false\n\n  # The twin: the same actions, table width, store options and callbacks as the withheld\n  # resource, with no executing-only values. The comparator caller also performs\n  # the registry's declared allocation checkpoint after eligible ordinary Ash calls.\n\n  use Ash.Resource,\n    domain: AshOnetime.Test.ExitBoundary.Domain,\n    data_layer: AshPostgres.DataLayer,\n    extensions: [AshOnetime.Resource]\n\n  postgres do\n    table(\"ash_onetime_boundary_records\")\n    repo(AshOnetime.Test.Repo)\n  end\n\n  multitenancy do\n    strategy(:context)\n  end\n\n  attributes do\n    uuid_primary_key(:id)\n    attribute(:amount, :integer, public?: true, allow_nil?: false)\n    attribute(:retired, :boolean, public?: true, allow_nil?: false, default: false)\n  end\n\n  actions do\n    defaults([:read])\n\n    create :seed do\n      accept([:amount])\n    end",
      mutated:
        "defmodule AshOnetime.Test.ExitBoundary.Returned do\n  @moduledoc false\n\n  # The twin: the same actions, table width, store options and callbacks as the withheld\n  # resource, with no executing-only values. The comparator caller also performs\n  # the registry's declared allocation checkpoint after eligible ordinary Ash calls.\n\n  use Ash.Resource,\n    domain: AshOnetime.Test.ExitBoundary.Domain,\n    data_layer: AshPostgres.DataLayer,\n    extensions: [AshOnetime.Resource]\n\n  postgres do\n    table(\"ash_onetime_boundary_records\")\n    repo(AshOnetime.Test.Repo)\n  end\n\n  multitenancy do\n    strategy(:context)\n  end\n\n  attributes do\n    uuid_primary_key(:id)\n    attribute(:amount, :integer, public?: true, allow_nil?: false)\n    attribute(:retired, :boolean, public?: true, allow_nil?: false, default: false)\n  end\n\n  actions do\n    defaults([:read])\n\n    create :seed do\n      description(\"undeclared compiled field\")\n      accept([:amount])\n    end",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :declarations,
      rules: [:u13],
      opts: []
    },
    %{
      id: :pc_u13_dead_declaration,
      path: "test/support/exit_boundary/declaration_slots.ex",
      original: "  def all, do: MapSet.new(@slots)\n",
      mutated:
        "  def all, do: MapSet.new([{{Ash.Resource.Info, :actions, 1}, [0, :description]} | @slots])\n",
      action: :issue,
      branch: :execute,
      fault: nil,
      kind: :declarations,
      rules: [:u13],
      opts: []
    },
    %{
      id: :pc_u13_dead_hook,
      path: "test/support/exit_boundary/registry.ex",
      original:
        "      slots: %{action: [before_action: 0, after_action: 1], crud: [around_action: 0]}\n",
      mutated:
        "      slots: %{action: [before_action: 0, after_action: 1, after_action: 0], crud: [around_action: 0]}\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :completeness,
      rules: [],
      opts: []
    },
    %{
      id: :pc_u13_dead_copy,
      path: "test/support/exit_boundary/registry.ex",
      original:
        "      slots: [{AshOnetime.GenericAction, :run, 3}, {AshOnetime.GenericAction, :run_original, 3}]\n",
      mutated:
        "      slots: [{AshOnetime.GenericAction, :run, 3}, {AshOnetime.GenericAction, :run_original, 3}, {AshOnetime.GenericAction, :never_copied, 3}]\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :completeness,
      rules: [],
      opts: []
    },
    %{
      id: :pc_u13_dead_frame,
      path: "test/support/exit_boundary/path_frames.ex",
      original:
        "      %{mfa: {Delivery, :armed, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n",
      mutated:
        "      %{mfa: {Delivery, :never_suspended, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n      %{mfa: {Delivery, :armed, 4}, anchor: entry, source: {:armed, 4, :dispatch, 2}},\n",
      action: :issue,
      branch: :consumer_failure,
      fault: :after_raise,
      kind: :completeness,
      rules: [],
      opts: []
    }
  ]

  def rows, do: @rows

  def observation_checks do
    %{
      "u_consumer_observation" => %{
        path: "test/support/exit_boundary/comparator.ex",
        original: "  defp canonical_event({pid, :call, {m, f, args}}, side) do\n",
        mutated:
          "  defp canonical_event(\n         {pid, :call, {AshOnetime.Test.ExitBoundary.Consumer, :after_action, [subject, result]}},\n         _side\n       ) do\n    private = Map.drop(subject.context.private, [:ash_onetime_delivery, :ash_onetime_delivery_cell])\n    subject = %{subject | context: %{subject.context | private: private}}\n    {pid, :call, {AshOnetime.Test.ExitBoundary.Consumer, :after_action, [subject, result]}}\n  end\n\n  defp canonical_event({pid, :call, {m, f, args}}, side) do\n",
        test: "test/ash_onetime/delivery/comparator_controls_test.exs",
        tag: "u_consumer_observation",
        test_name: "U observation: Consumer arguments remain unprojected",
        assertion: "U_CONSUMER_ARGUMENT_WITNESS"
      },
      "u_error_observation" => %{
        path: "test/support/exit_boundary/comparator.ex",
        original:
          "  defp term(%AshOnetime.Resource.Response{} = a, %AshOnetime.Resource.Response{} = b, state, path) do\n",
        mutated:
          "  defp term(%AshOnetime.Error{} = a, %AshOnetime.Error{} = b, state, path) do\n    term(Map.delete(Map.from_struct(a), :details), Map.delete(Map.from_struct(b), :details), state, path)\n  end\n\n  defp term(%AshOnetime.Resource.Response{} = a, %AshOnetime.Resource.Response{} = b, state, path) do\n",
        test: "test/ash_onetime/delivery/comparator_controls_test.exs",
        tag: "u_error_observation",
        test_name: "U observation: captured error details remain exact",
        assertion: "U_ERROR_DETAILS_WITNESS"
      },
      "u_store_observation" => %{
        path: "test/support/exit_boundary/comparator.ex",
        original: "    state = store(run.delta, twin.delta, %{state | at: :store})\n",
        mutated: "    state = %{state | at: :store}\n",
        test: "test/ash_onetime/delivery/comparator_controls_test.exs",
        tag: "u_store_observation",
        test_name: "U observation: real snapshots retain every row and column",
        assertion: "U_STORE_SNAPSHOT_WITNESS"
      },
      "u_wire_statement_phase" => %{
        path: "test/support/exit_boundary/comparator.ex",
        original: "    rw = Wire.build(rt, readback.claimed)\n",
        mutated: "    rw = Wire.build(rt)\n",
        test: "test/ash_onetime/delivery/comparator_controls_test.exs",
        tag: "u2",
        test_name: "U2 and U4: hold release reaches GREATEST and its next wire row",
        assertion: "comparator differences:"
      },
      "u_allocation_happens_before" => %{
        path: "test/support/exit_boundary/allocation.ex",
        original:
          "        errors ++\n          order_errors ++\n          errors_for_leases(left ++ right) ++\n          joined_borrowers(left, rc) ++ joined_borrowers(right, tc),\n",
        mutated:
          "        errors ++\n          Enum.take(order_errors, 0) ++\n          errors_for_leases(left ++ right) ++\n          Enum.take(joined_borrowers(left, rc) ++ joined_borrowers(right, tc), 0),\n",
        test: "test/ash_onetime/delivery/comparator_controls_test.exs",
        tag: "u_allocation_happens_before",
        test_name: "U observation: overlapping borrowers require causal checkin order",
        assertion: "U_ALLOCATION_HAPPENS_BEFORE_WITNESS"
      },
      "u_cross_lease_observation" => %{
        path: "test/support/exit_boundary/allocation.ex",
        original: "      bind_lease(acc, a, b)\n",
        mutated: "      _ = acc\n      bind_lease(initial, a, b)\n",
        test: "test/ash_onetime/delivery/comparator_controls_test.exs",
        tag: "u_cross_lease_observation",
        test_name:
          "U observation: physical identity remains bound across independent native leases",
        assertion: "U_CROSS_LEASE_IDENTITY_WITNESS"
      }
    }
  end

  def checks do
    Map.new(@rows, fn row ->
      name = Atom.to_string(row.id)

      {name,
       Map.merge(row, %{
         test: "test/ash_onetime/delivery/comparator_positive_controls_test.exs",
         tag: name,
         test_name: name <> ": qualified origin positive control",
         assertion: String.upcase(name) <> "_QUALIFIED_ORIGIN_REJECTED"
       })}
    end)
    |> Map.merge(observation_checks())
  end
end
