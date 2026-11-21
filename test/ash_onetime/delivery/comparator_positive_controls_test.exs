Code.require_file("../../../scripts/delivery_comparator_controls.exs", __DIR__)

defmodule AshOnetime.Delivery.ComparatorPositiveControlsTest do
  alias AshOnetime.Test.ExitBoundary.Comparator
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.Completeness
  alias AshOnetime.Test.ExitBoundary.Declarations
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.Returned
  alias AshOnetime.Test.ExitBoundary.Scenarios
  alias AshOnetime.Test.ExitBoundary.Search
  alias AshOnetime.Test.ExitBoundary.Values
  alias AshOnetime.Test.ExitBoundary.Withheld
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  for control <- AshOnetime.DeliveryComparatorControls.rows() do
    @tag control.id
    @tag :comparator_positive_control
    test "#{control.id}: qualified origin positive control", context do
      control =
        Enum.find(AshOnetime.DeliveryComparatorControls.rows(), &(&1.id == unquote(control.id)))

      errors =
        with_runtime(control, fn ->
          case control.kind do
            :declarations ->
              Declarations.pair(Withheld, Returned).errors

            :completeness ->
              completeness_errors(control, context)

            :comparison ->
              row =
                row!(control.action, control.branch, control.fault)
                |> Map.put(:opts, control.opts)

              pair = observe(context, row, Values.set()[:va])
              hits = Search.hits(pair.run)
              quiet? = hits == []

              assert quiet?,
                     "a positive control crossed a raw-canary exit: #{Diagnostics.render(hits)}"

              Comparator.compare(pair).errors
          end
        end)

      if control.id == :pc_o4_date_copy and errors != [] do
        assert match?(
                 %{at: %{mfa: {AshOnetime.Store.Postgres, :dispatched_query, 3}}, rule: :o4},
                 hd(errors)
               ),
               "the altered date copy must be the first native divergence"
      end

      if errors != [] do
        IO.puts(
          "QUALIFIED_ORIGIN_CONTROL" <>
            ": " <>
            Diagnostics.render(%{control: control.id, errors: Diagnostics.safe(errors)},
              pretty: true,
              limit: :infinity
            )
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

  defp with_runtime(%{id: :pc_o4_date_copy, path: path, action: action}, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_DATE_OPERATION") do
      {:ok, operation} = AshOnetime.Test.ExitBoundary.Registry.operation(Withheld, action)

      source =
        String.replace(source, "COMPARATOR_DATE_OPERATION", inspect(operation, limit: :infinity))

      Compiled.with_source(source, path, callback)
    else
      callback.()
    end
  end

  defp with_runtime(_, callback), do: callback.()

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
        pairs =
          for row <- Scenarios.rows(),
              row.branch == :consumer_failure and row.fault == :after_raise do
            pair = observe(context, row, Values.set()[:va])

            comparison = Comparator.compare(pair)
            baseline? = comparison.errors == []

            assert baseline?,
                   "U13 needs an accepted real capture before adding a dead registry slot"

            pair
          end

        assert Completeness.check(pairs) == %{
                 declarations: [],
                 hooks: MapSet.new(),
                 copies: MapSet.new(),
                 frames: MapSet.new()
               },
               "U13 baseline must have every live witness before the dead-slot mutation"

        pairs
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
