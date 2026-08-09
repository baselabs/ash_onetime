defmodule AshOnetime.Resource.VerifierTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Info
  alias AshOnetime.Test.Support.Resource

  @tag wrapper_protection_mutation: true
  test "postcompile verifier accepts exact normalized wrapper protection" do
    assert {:module, AshOnetime.Resource.Verifier} =
             Code.ensure_loaded(AshOnetime.Resource.Verifier)

    assert function_exported?(AshOnetime.Resource.Verifier, :verify, 1)
    assert length(Info.protections(Resource)) == 2

    protection = Info.protection(Resource, :charge)
    change = Resource |> Ash.Resource.Info.action(:charge) |> Map.fetch!(:changes) |> List.first()

    assert %Ash.Resource.Change{change: {AshOnetime.Change, opts}} = change
    assert opts[:protection] == protection
  end
end
