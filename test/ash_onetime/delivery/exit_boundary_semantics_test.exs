defmodule AshOnetime.Delivery.ExitBoundarySemanticsTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.ExitBoundary.{Analysis, Persisted}
  alias AshOnetime.Test.ExitBoundary.Analysis.Event

  @moduletag exit_boundary_semantics: true

  test "X2 and X3 preserve existing binary and numeric values" do
    for {left, right} <- [{"original", "inverted"}, {7, 8}] do
      refute Analysis.shape(%{value: left}, %{}) == Analysis.shape(%{value: right}, %{})
    end
  end

  test "X1 preserves same-width opaque binary values" do
    delta = fn bytes -> %{"records" => %{added: [%{"opaque" => bytes}], removed: []}} end
    left = Persisted.normalize(delta.(<<0, 1, 2, 3>>), "fixture", %{})
    right = Persisted.normalize(delta.(<<4, 5, 6, 7>>), "fixture", %{})
    refute Persisted.difference(left, right) == []
  end

  test "X2 preserves repeated non-transport events" do
    event = %Event{
      pid: self(), event: {self(), :call, {:logger, :update_process_metadata, [%{note: "same"}]}},
      mfa: {:logger, :update_process_metadata, 1}, class: :e14, kind: :event,
      stack: [], region: :body
    }
    side = %{host: [], package?: false}
    one = Analysis.emitted([event], side, %{})
    two = Analysis.emitted([event, event], side, %{})
    refute Analysis.emitted_difference(one, two) == []
  end

  test "X2 and X3 preserve argument payloads in package and Ash entry frames" do
    for module <- [AshOnetime.Admission, Ash, AshOnetime.Delivery] do
      stack = fn value -> [{module, :call, [value], [file: ~c"fixture.ex", line: 1]}] end
      refute Analysis.shape(stack.("original"), %{}) == Analysis.shape(stack.("inverted"), %{})
    end
  end

  test "X2 compares every protection setting outside the declared fixture differences" do
    protection = %AshOnetime.Resource.Protection{retention: 60, scope: [{:static, "boundary"}]}
    for changed <- [%{protection | retention: 61}, %{protection | scope: [{:static, "elsewhere"}]},
                    %{protection | on_definite_store_failure: :execute_untracked}] do
      refute Analysis.shape(protection, %{}) == Analysis.shape(changed, %{})
    end
  end
end
