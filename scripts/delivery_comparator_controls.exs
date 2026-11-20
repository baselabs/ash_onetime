defmodule AshOnetime.DeliveryComparatorControls do
  @moduledoc false

  @rows [
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
        "defmodule AshOnetime.Test.ExitBoundary.Returned do\n  @moduledoc false\n\n  # The twin: the same actions, table width, store options and callbacks as the withheld\n  # resource, with no executing-only values. Every boundary run is compared with it.\n\n  use Ash.Resource,\n    domain: AshOnetime.Test.ExitBoundary.Domain,\n    data_layer: AshPostgres.DataLayer,\n    extensions: [AshOnetime.Resource]\n\n  postgres do\n    table(\"ash_onetime_boundary_records\")\n    repo(AshOnetime.Test.Repo)\n  end\n\n  multitenancy do\n    strategy(:context)\n  end\n\n  attributes do\n    uuid_primary_key(:id)\n    attribute(:amount, :integer, public?: true, allow_nil?: false)\n    attribute(:retired, :boolean, public?: true, allow_nil?: false, default: false)\n  end\n\n  actions do\n    defaults([:read])\n\n    create :seed do\n      accept([:amount])\n    end",
      mutated:
        "defmodule AshOnetime.Test.ExitBoundary.Returned do\n  @moduledoc false\n\n  # The twin: the same actions, table width, store options and callbacks as the withheld\n  # resource, with no executing-only values. Every boundary run is compared with it.\n\n  use Ash.Resource,\n    domain: AshOnetime.Test.ExitBoundary.Domain,\n    data_layer: AshPostgres.DataLayer,\n    extensions: [AshOnetime.Resource]\n\n  postgres do\n    table(\"ash_onetime_boundary_records\")\n    repo(AshOnetime.Test.Repo)\n  end\n\n  multitenancy do\n    strategy(:context)\n  end\n\n  attributes do\n    uuid_primary_key(:id)\n    attribute(:amount, :integer, public?: true, allow_nil?: false)\n    attribute(:retired, :boolean, public?: true, allow_nil?: false, default: false)\n  end\n\n  actions do\n    defaults([:read])\n\n    create :seed do\n      description(\"undeclared compiled field\")\n      accept([:amount])\n    end",
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
  end
end
