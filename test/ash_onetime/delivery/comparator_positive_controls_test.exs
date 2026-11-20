Code.require_file("../../../scripts/delivery_comparator_controls.exs", __DIR__)

defmodule AshOnetime.Delivery.ComparatorPositiveControlsTest do
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  alias AshOnetime.Test.ExitBoundary.{
    Comparator,
    Completeness,
    Declarations,
    Diagnostics,
    Returned,
    Search,
    Values,
    Withheld
  }

  for control <- AshOnetime.DeliveryComparatorControls.rows() do
    @tag control.id
    @tag :comparator_positive_control
    test "#{control.id}: qualified origin positive control", context do
      control = unquote(Macro.escape(control))

      errors =
        case control.kind do
          :declarations ->
            Declarations.pair(Withheld, Returned).errors

          :completeness ->
            completeness_errors(control, context)

          :comparison ->
            row =
              row!(control.action, control.branch, control.fault) |> Map.put(:opts, control.opts)

            pair = observe(context, row, Values.set()[:va])
            hits = Search.hits(pair.run)
            quiet? = hits == []
            assert quiet?, "a positive control crossed a raw-canary exit: #{inspect(hits)}"
            Comparator.compare(pair).errors
        end

      if errors != [] do
        IO.inspect(%{control: control.id, errors: Diagnostics.safe(errors)},
          label: "QUALIFIED_ORIGIN_CONTROL",
          limit: :infinity
        )

        owned? =
          if control.kind in [:declarations, :completeness],
            do: true,
            else: Enum.any?(errors, &qualified?(control, &1))

        assert owned?,
               "#{control.id}: a different rule failed; this is not the claimed positive control"
      end

      clear? = errors == []
      assert clear?, String.upcase(Atom.to_string(control.id)) <> "_QUALIFIED_ORIGIN_REJECTED"
    end
  end

  defp qualified?(%{id: :pc_return_raw}, error),
    do:
      match?(
        %{at: %{mfa: {AshOnetime.Delivery, :normalize, 3}}, path: [:return, :raw | _]},
        error
      )

  defp qualified?(%{id: :pc_return_destroy}, error),
    do:
      match?(%{at: %{mfa: {AshOnetime.Delivery, :normalize, 3}}, rule: :permitted_return}, error)

  defp qualified?(%{id: :pc_o2a_binding}, error),
    do:
      match?(
        %{at: %{mfa: {AshOnetime.Delivery.Envelope, :context, 4}}, rule: :envelope_binding},
        error
      )

  defp qualified?(%{id: id}, error)
       when id in [:pc_context_copy_ref, :pc_context_copy_cell, :pc_context_copy_admitted],
       do:
         match?(
           %{
             at: %{mfa: {AshOnetime.GenericAction, :run_original, 3}},
             rule: :context_copy,
             path: [:args, 2, :source_context]
           },
           error
         )

  defp qualified?(control, error), do: error.rule in control.rules

  defp completeness_errors(control, context) do
    source = File.read!(control.path)
    mutated? = String.contains?(source, control.mutated)

    if mutated?,
      do:
        compile_reference(String.replace(source, control.mutated, control.original), control.path)

    pairs =
      try do
        for action <- [:issue, :rotate, :revoke, :mint] do
          pair =
            observe(context, row!(action, :consumer_failure, :after_raise), Values.set()[:va])

          comparison = Comparator.compare(pair)
          baseline? = comparison.errors == []

          assert baseline?,
                 "U13 needs an accepted real capture before adding a dead registry slot"

          pair
        end
      after
        if mutated?, do: compile_reference(source, control.path)
      end

    for {kind, dead} <- Completeness.check(pairs), item <- Enum.to_list(dead), do: {kind, item}
  end

  defp compile_reference(source, path) do
    # This test executes only on the build host. Capture under the original
    # registry, then install the edited registry before auditing those captures.
    # Captured events and closure environments are never edited.
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_string(source, path)
    after
      Code.compiler_options(previous)
    end
  end
end
