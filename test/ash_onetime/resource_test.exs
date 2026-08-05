defmodule AshOnetime.ResourceTest do
  use ExUnit.Case, async: true

  alias AshOnetime.KeySource
  alias AshOnetime.Resource.Info
  alias AshOnetime.Resource.Protection
  alias AshOnetime.Scope
  alias AshOnetime.Test.Support.Resource

  defmodule ExplodingRun do
    use Ash.Resource.Actions.Implementation

    @impl true
    def run(_input, _opts, _context), do: raise("original generic run was invoked")
  end

  test "one resource compiles both explicit strategies without an operation override" do
    protections = Info.protections(Resource)

    assert Enum.map(protections, & &1.strategy) == [:idempotency, :one_time_nonce]
    refute :operation in Map.keys(%Protection{})
    refute :operation_hash in Map.keys(%Protection{})
  end

  test "injected change installs transactional admission hooks without eager execution" do
    protection = Info.protection(Resource, :charge)
    changeset = Ash.Changeset.new(Resource)

    assert {:ok, opts} = AshOnetime.Change.init(protection: protection)
    changed = AshOnetime.Change.change(changeset, opts, %{})
    assert changed.valid?
    assert length(changed.before_action) == 1
    assert length(changed.around_action) == 1

    assert {:not_atomic, "keyed effects require transactional stream execution"} =
             AshOnetime.Change.atomic(changeset, opts, %{})
  end

  test "generic wrapper fails closed and does not invoke its original implementation" do
    protection = Info.protection(Resource, :redeem)

    assert {:error, %AshOnetime.Error{code: :admission_unavailable}} =
             AshOnetime.GenericAction.run(
               nil,
               [protection: protection, original: {ExplodingRun, []}],
               %{}
             )
  end

  test "key sources are closed, bounded, flat, and uniquely referenced" do
    assert {:ok, [{:argument, :key}, {:attribute, :account_id}]} =
             KeySource.normalize([{:argument, :key}, {:attribute, :account_id}])

    assert %{arguments: [:external_key, :client_key, :key], attributes: [:account_id]} =
             KeySource.references([
               {:argument, :key},
               {:client, :client_key},
               {:external, :external_key},
               {:attribute, :account_id}
             ])

    assert {:error, _message} = KeySource.normalize([])
    assert {:error, _message} = KeySource.normalize([[{:argument, :key}]])
    assert {:error, _message} = KeySource.normalize([{:argument, :key}, {:argument, :key}])
    assert {:error, _message} = KeySource.normalize(Enum.map(1..17, &{:argument, :"key#{&1}"}))
    assert {:error, _message} = KeySource.normalize({:unknown, :key})
  end

  test "scope components are explicit, closed, bounded, and nonempty" do
    assert {:ok, [{:static, "charge"}, {:attribute, :account_id}]} =
             Scope.normalize([{:static, "charge"}, {:attribute, :account_id}])

    assert {:error, _message} = Scope.normalize([])
    assert {:error, _message} = Scope.normalize([{:static, ""}])
    assert {:error, _message} = Scope.normalize([{:static, "x"}, {:static, "x"}])
    assert {:error, _message} = Scope.normalize(Enum.map(1..17, &{:static, "scope#{&1}"}))
    assert {:error, _message} = Scope.normalize([{:global, true}])
  end
end
