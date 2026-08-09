defmodule AshOnetime.ChangeTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Protection
  alias AshOnetime.Test.ActionExamples.Resource

  test "change installs admission before-hook and outer completion hook without doing I/O" do
    protection = %Protection{strategy: :idempotency, action: :charge}
    changeset = Ash.Changeset.for_create(Resource, :charge, valid_input())

    changed = AshOnetime.Change.change(changeset, [protection: protection], %{})

    assert length(changed.before_action) == length(changeset.before_action) + 1
    assert length(changed.around_action) == length(changeset.around_action) + 1
    assert changed.valid?
  end

  @tag atomic_shape_mutation: true
  test "protected changes force transactional stream execution" do
    assert {:not_atomic, "keyed effects require transactional stream execution"} =
             AshOnetime.Change.atomic(nil, [], %{})
  end

  defp valid_input do
    %{
      account_id: Ecto.UUID.generate(),
      amount: 10,
      request_key: "request-1",
      natural_key: "natural-1",
      external_key: "external-1"
    }
  end
end
