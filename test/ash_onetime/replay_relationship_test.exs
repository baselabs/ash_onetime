defmodule AshOnetime.ReplayRelationshipTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.ReplayRelationships.{BrokenPure, Parent}

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(Repo, ~s|CREATE TABLE "#{prefix}".replay_parents (
      id uuid PRIMARY KEY, value bigint, owner_id uuid)|, [])

    SQL.query!(Repo, ~s|CREATE TABLE "#{prefix}".replay_related (
      id uuid PRIMARY KEY, parent_id uuid, label text)|, [])

    SQL.query!(Repo, ~s|CREATE TABLE "#{prefix}".replay_hook_writes (label text)|, [])
    :ok
  end

  for action <- [:create, :update, :destroy], relationship <- [:children, :owner] do
    @tag :replay_relationship_clear_mutation
    test "#{action} replay clears caller-managed #{relationship} and returns the stored result",
         %{
           prefix: prefix
         } do
      action = unquote(action)
      relationship = unquote(relationship)
      record = seed(action, prefix)
      key = Ecto.UUID.generate()

      assert {:ok, fresh} = call(action, record, prefix, key, relationship, "fresh")
      fresh_count = related_count(prefix, "fresh")
      assert fresh_count == 1

      assert {:ok, replayed} = call(action, record, prefix, key, relationship, "replayed")
      assert related_count(prefix, "replayed") == 0

      assert Map.take(replayed, [:id, :value, :owner_id]) ==
               Map.take(fresh, [:id, :value, :owner_id])

      assert AshOnetime.replayed?(replayed)
    end
  end

  for action <- [:create, :update, :destroy] do
    @tag :replay_relationship_backstop_mutation
    test "#{action} replay rolls back a lying pure hook even with rollback_on_error?: false", %{
      prefix: prefix
    } do
      action = unquote(action)
      record = seed(action, prefix)
      key = Ecto.UUID.generate()
      assert {:ok, _fresh} = call(action, record, prefix, key)

      Process.put({BrokenPure, :break?}, true)
      assert {:error, error} = call(action, record, prefix, key)
      assert AshOnetime.Error.code(error) == :replay_relationship_change
      leaf = Enum.find(error.errors, &match?(%AshOnetime.Error{}, &1))
      assert leaf.message == "relationship changes cannot run on a replay"
      assert leaf.details == %{}

      assert %{rows: [[0]]} =
               SQL.query!(Repo, ~s|SELECT count(*) FROM "#{prefix}".replay_hook_writes|, [])

      assert related_count(prefix, "late") == 0
    end
  end

  test "declared replay-aware hooks run on fresh execution and replay", %{prefix: prefix} do
    key = Ecto.UUID.generate()
    assert {:ok, _} = call(:create, Parent, prefix, key)
    assert_receive {:relationship_replay_hook, false}
    assert {:ok, _} = call(:create, Parent, prefix, key)
    assert_receive {:relationship_replay_hook, true}
  end

  test "generic action inputs have no public changeset relationship surface", %{prefix: prefix} do
    input = generic_input(prefix, Ecto.UUID.generate())
    refute Map.has_key?(input, :relationships)

    assert_raise KeyError, fn ->
      Ash.Changeset.manage_relationship(input, :children, %{label: "invalid"}, type: :create)
    end

    assert {:ok, 7} = Ash.run_action(input)
    assert {:ok, 7} = Ash.run_action(input)
  end

  @tag :generic_replay_relationship_mutation
  test "generic completion rolls back relationship state injected by a caller hook", %{
    prefix: prefix
  } do
    input = generic_input(prefix, Ecto.UUID.generate())
    assert {:ok, 7} = Ash.run_action(input)

    replay =
      Ash.ActionInput.before_action(input, fn pending ->
        SQL.query!(
          Repo,
          ~s|INSERT INTO "#{prefix}".replay_hook_writes (label) VALUES ('generic')|,
          []
        )

        Map.put(pending, :relationships, %{children: []})
      end)

    assert {:error, error} = Ash.run_action(replay)
    assert AshOnetime.Error.code(error) == :replay_relationship_change

    assert %{rows: [[0]]} =
             SQL.query!(Repo, ~s|SELECT count(*) FROM "#{prefix}".replay_hook_writes|, [])
  end

  defp generic_input(prefix, key) do
    Parent
    |> Ash.ActionInput.for_action(:generic_once, %{value: 7, request_key: key})
    |> Ash.ActionInput.set_tenant(prefix)
  end

  defp seed(:create, _prefix), do: Parent

  defp seed(_action, prefix) do
    Parent
    |> Ash.Changeset.for_create(:create, %{value: 1}, tenant: prefix)
    |> Ash.Changeset.force_change_attribute(:owner_id, Ecto.UUID.generate())
    |> Ash.create!()
  end

  defp call(action, record, prefix, key, relationship \\ nil, label \\ nil) do
    changeset =
      case action do
        :create ->
          Ash.Changeset.for_create(record, :create_once, %{value: 2, request_key: key},
            tenant: prefix
          )

        :update ->
          Ash.Changeset.for_update(record, :update_once, %{value: 2, request_key: key},
            tenant: prefix
          )

        :destroy ->
          Ash.Changeset.for_destroy(record, :destroy_once, %{request_key: key}, tenant: prefix)
      end

    changeset =
      if relationship do
        Ash.Changeset.manage_relationship(changeset, relationship, %{label: label}, type: :create)
      else
        changeset
      end

    case action do
      :create -> Ash.create(changeset, rollback_on_error?: false)
      :update -> Ash.update(changeset, rollback_on_error?: false)
      :destroy -> Ash.destroy(changeset, rollback_on_error?: false, return_destroyed?: true)
    end
  end

  defp related_count(prefix, label) do
    %{rows: [[count]]} =
      SQL.query!(Repo, ~s|SELECT count(*) FROM "#{prefix}".replay_related WHERE label = $1|, [
        label
      ])

    count
  end
end
