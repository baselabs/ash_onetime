defmodule AshOnetime.CallbackResultTest do
  use ExUnit.Case, async: false

  alias AshOnetime.{Admission, Error, Verified}
  alias AshOnetime.Resource.Info, as: ResourceInfo
  alias AshOnetime.Test.ActionExamples.Resource

  defmodule Facts do
    @moduledoc false
    def verify(_, _), do: :persistent_term.get(__MODULE__)
    def mint(_), do: :persistent_term.get(__MODULE__)
  end

  setup do
    on_exit(fn -> :persistent_term.erase(Facts) end)
  end

  test "malformed trusted facts are verifier contract violations for verifiers and minters" do
    {:ok, valid} = Verified.new(key: "nonce", issued_at: DateTime.utc_now(), verifier_id: "facts")

    for kind <- [:verifier, :minter],
        facts <- [
          %{valid | key: ""},
          %{valid | verifier_id: :binary.copy("x", 129)},
          %{valid | issued_at: %{valid.issued_at | month: 13}},
          %{valid | expires_at: DateTime.add(valid.issued_at, -1)}
        ] do
      :persistent_term.put(Facts, {:ok, facts})
      source = if kind == :verifier, do: {:verified, :proof, Facts}, else: {:minted, Facts}
      assert {:error, %Error{code: :verifier_contract_violation}} = prepare(source, "proof")
    end
  end

  test "malformed untrusted input remains verification_failed before a verifier runs" do
    for proof <- [nil, "", :binary.copy("x", 65_537)] do
      assert {:error, %Error{code: :verification_failed}} =
               prepare({:verified, :proof, Facts}, proof)
    end
  end

  defp prepare(source, proof) do
    input =
      Ash.ActionInput.for_action(Resource, :consume, %{proof: proof, value: 1},
        tenant: "callbacks"
      )

    protection = ResourceInfo.protection(Resource, :consume)
    Admission.prepare(input, %{protection | key: [source]}, %{})
  end
end
