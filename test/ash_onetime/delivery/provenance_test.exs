defmodule AshOnetime.Delivery.ProvenanceTest do
  # §2.7.5: `deliver/2` takes its outcome only from the `:done` entry, and completion is the
  # one place that writes it. Each row arms an entry exactly as `deliver/2` does, drives the
  # real claim, seal and complete functions with the delivery source that row's path sets on
  # admission's state, and reads the entry `deliver/2` would open. The paths themselves run
  # end to end in the delivery, recovery and rollback tests; this file pins the mapping.
  use ExUnit.Case, async: true

  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples.Resource

  @names [:secret]

  @moduletag executing_only_provenance: true

  test "a fresh execute, local or external, completes with its sealed envelope" do
    {handle, key} = claimed()
    :ok = Delivery.seal(handle, %{secret: "provenance-value"})

    assert :ok = Delivery.complete(handle, executed_state())
    assert {:done, inv, :executed, envelope, {:target, %{id: "claim"}}} = Process.get(key)
    assert inv == handle.inv
    assert is_binary(envelope)
  end

  for source <- [:recovered, :replayed] do
    @source source

    test "#{source} completes a claimed entry with no values" do
      {handle, key} = claimed()

      assert :ok = Delivery.complete(handle, %{delivery_source: @source})
      assert {:done, inv, @source, nil, nil} = Process.get(key)
      assert inv == handle.inv
    end
  end

  test "finalize resolves to a replay: the sealed values are dropped and the outcome is :replayed" do
    {handle, key} = claimed()
    :ok = Delivery.seal(handle, %{secret: "provenance-value"})

    assert :ok = Delivery.complete(handle, %{executed_state() | delivery_source: :replayed})
    assert {:done, inv, :replayed, nil, nil} = Process.get(key)
    assert inv == handle.inv
  end

  test "a recovery that meets a sealed entry is lost" do
    {handle, key} = claimed()
    :ok = Delivery.seal(handle, %{secret: "provenance-value"})

    assert lost?(Delivery.complete(handle, %{executed_state() | delivery_source: :recovered}))
    assert {:sealed, _inv, _envelope} = Process.get(key)
  end

  test "an executed completion with nothing sealed is lost" do
    {handle, key} = claimed()

    assert lost?(Delivery.complete(handle, executed_state()))
    assert {:claimed, _inv, _public} = Process.get(key)
  end

  test "an executed completion without the store target and exact claim is lost" do
    {handle, _key} = claimed()
    :ok = Delivery.seal(handle, %{secret: "provenance-value"})

    assert lost?(Delivery.complete(handle, %{delivery_source: :executed}))
    assert lost?(Delivery.complete(handle, %{executed_state() | target: nil}))
    assert lost?(Delivery.complete(handle, %{executed_state() | claim: %{id: nil}}))
  end

  test "a completion without a delivery source is lost" do
    {handle, _key} = claimed()

    assert lost?(Delivery.complete(handle, %{}))
    assert lost?(Delivery.complete(handle, %{delivery_source: nil}))
  end

  test "a completion by another invocation is lost" do
    {handle, key} = claimed()

    assert lost?(Delivery.complete(%{handle | inv: <<0::128>>}, %{delivery_source: :replayed}))
    assert {:claimed, _inv, _public} = Process.get(key)
  end

  test "an entry spent by a nested invocation is lost at the entry check" do
    {subject, cell, key} = armed()
    assert {:ok, _handle} = Delivery.claim(subject, cell, @names)

    assert {:error, error} = Delivery.claim(subject, cell, @names)
    assert AshOnetime.Error.code(error) == :executing_only_lost
    assert {:claimed, _inv, _public} = Process.get(key)
  end

  # Arms the entry the way `deliver/2` does: the subject carries the cell and `%{ref: ref}`,
  # and the entry under H(ref) holds this pid, the resource, the action, the cell and the
  # public key.
  defp armed do
    ref = :crypto.strong_rand_bytes(16)
    {public, _secret} = :crypto.generate_key(:ecdh, :x25519)

    {changeset, cell} =
      Resource
      |> Ash.Changeset.for_create(:issue, %{amount: 1, request_key: "provenance"},
        tenant: "provenance"
      )
      |> Delivery.put_cell()

    private = Map.put(changeset.context.private, :ash_onetime_delivery, %{ref: ref})
    subject = %{changeset | context: Map.put(changeset.context, :private, private)}
    key = Delivery.key(ref)
    Process.put(key, {:armed, self(), subject.resource, subject.action.name, cell, public})
    {subject, cell, key}
  end

  defp claimed do
    {subject, cell, key} = armed()
    {:ok, handle} = Delivery.claim(subject, cell, @names)
    {handle, key}
  end

  defp executed_state, do: %{delivery_source: :executed, target: :target, claim: %{id: "claim"}}

  defp lost?({:error, error}), do: AshOnetime.Error.code(error) == :executing_only_lost
  defp lost?(_other), do: false
end
