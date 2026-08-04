defmodule AshOnetime.Resource.VerifierTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Info
  alias AshOnetime.Test.Support.Resource

  test "postcompile verifier accepts transformer postconditions" do
    assert {:module, AshOnetime.Resource.Verifier} =
             Code.ensure_loaded(AshOnetime.Resource.Verifier)

    assert function_exported?(AshOnetime.Resource.Verifier, :verify, 1)
    assert length(Info.protections(Resource)) == 2
  end
end
