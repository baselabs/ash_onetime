defmodule AshOnetime.ReplayRelationshipCallbackErrorTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.ReplayRelationships.{BrokenPure, Parent, ResultAllowed}

  @moduletag :unboxed

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(Repo, ~s|CREATE TABLE IF NOT EXISTS "#{prefix}".replay_parents (
      id uuid PRIMARY KEY, value bigint, owner_id uuid)|, [])

    SQL.query!(Repo, ~s|CREATE TABLE IF NOT EXISTS "#{prefix}".replay_related (
      id uuid PRIMARY KEY, parent_id uuid, label text)|, [])

    SQL.query!(
      Repo,
      ~s|CREATE TABLE IF NOT EXISTS "#{prefix}".replay_hook_writes (label text)|,
      []
    )

    SQL.query!(Repo, ~s|TRUNCATE "#{prefix}".replay_parents,
      "#{prefix}".replay_related, "#{prefix}".replay_hook_writes|, [])
    {:ok, reader: start_unboxed_repo!()}
  end

  for action <- [:create, :update, :destroy] do
    @tag :replay_callback_error_mutation
    test "#{action} replay rolls back writes and preserves an after-action error", context do
      action = unquote(action)
      %{prefix: prefix} = context
      record = seed(action, prefix)
      key = Ecto.UUID.generate()
      assert {:ok, _} = call(action, changeset(action, record, prefix, key))
      Process.put({BrokenPure, :break?}, true)
      expected = AshOnetime.Error.new(:invalid_option, "caller after-action refused", %{key: key})

      replay =
        action
        |> changeset(record, prefix, key)
        |> Ash.Changeset.after_action(fn pending, _result ->
          assert AshOnetime.Admission.replay?(pending)
          assert_writes(context, 1, 1)
          {:error, expected}
        end)

      assert {:error, error} = call(action, replay)
      assert_hook_error(error, expected)
      assert_committed_writes(context, 0, 0)
    end
  end

  @tag :replay_callback_error_mutation
  test "replay rolls back writes when a policy rejects the result", context do
    %{prefix: prefix} = context
    key = Ecto.UUID.generate()
    assert {:ok, fresh} = call(:create, changeset(:create, Parent, prefix, key), authorize?: true)
    assert_receive {:relationship_result_check, [id], true}
    assert id == fresh.id
    Process.put({BrokenPure, :break?}, true)
    Process.put({ResultAllowed, :refuse?}, true)

    replay =
      :create
      |> changeset(Parent, prefix, key)
      |> Ash.Changeset.after_action(fn pending, result ->
        assert AshOnetime.Admission.replay?(pending)
        assert_writes(context, 1, 1)
        {:ok, result}
      end)

    assert {:error, %Ash.Error.Forbidden{}} = call(:create, replay, authorize?: true)
    assert_receive {:relationship_result_check, [^id], true}
    assert_committed_writes(context, 0, 0)
  end

  @tag :replay_callback_error_mutation
  test "replay rolls back partial relationship management", context do
    %{prefix: prefix} = context
    key = Ecto.UUID.generate()
    assert {:ok, _} = call(:create, changeset(:create, Parent, prefix, key))
    Process.put({BrokenPure, :break?}, :partial)

    assert {:error, error} = call(:create, changeset(:create, Parent, prefix, key))
    assert Exception.message(error) =~ "changes would create a new related record"
    # One relationship batch created a child; the next batch refused a missing child.
    assert_receive {:relationship_child_written, "late"}
    assert_committed_writes(context, 0, 0)
  end

  for action <- [:create, :update, :destroy] do
    test "#{action} fresh execution preserves rollback_on_error?: false", context do
      action = unquote(action)
      %{prefix: prefix} = context
      record = seed(action, prefix)
      key = Ecto.UUID.generate()
      Process.put({BrokenPure, :break?}, true)
      expected = AshOnetime.Error.new(:invalid_option, "fresh caller after-action refused")

      fresh =
        action
        |> changeset(record, prefix, key)
        |> Ash.Changeset.after_action(fn pending, _result ->
          refute AshOnetime.Admission.replay?(pending)
          {:error, expected}
        end)

      assert {:error, error} = call(action, fresh)
      assert_hook_error(error, expected)
      assert_committed_writes(context, 1, 1)
    end
  end

  defp seed(:create, _prefix), do: Parent

  defp seed(_action, prefix) do
    Parent
    |> Ash.Changeset.for_create(:create, %{value: 1}, tenant: prefix)
    |> Ash.create!()
  end

  defp changeset(:create, record, prefix, key),
    do:
      Ash.Changeset.for_create(record, :create_once, %{value: 2, request_key: key},
        tenant: prefix
      )

  defp changeset(:update, record, prefix, key),
    do:
      Ash.Changeset.for_update(record, :update_once, %{value: 2, request_key: key},
        tenant: prefix
      )

  defp changeset(:destroy, record, prefix, key),
    do: Ash.Changeset.for_destroy(record, :destroy_once, %{request_key: key}, tenant: prefix)

  defp call(action, changeset, opts \\ []) do
    opts = Keyword.put(opts, :rollback_on_error?, false)

    case action do
      :create -> Ash.create(changeset, opts)
      :update -> Ash.update(changeset, opts)
      :destroy -> Ash.destroy(changeset, Keyword.put(opts, :return_destroyed?, true))
    end
  end

  defp assert_hook_error(error, expected) do
    leaf = Enum.find(error.errors, &match?(%AshOnetime.Error{}, &1))
    # Ash adds the same wrapper metadata whether the transaction commits or rolls back.
    assert leaf == %{expected | splode: Ash.Error, bread_crumbs: error.bread_crumbs}
  end

  defp assert_writes(%{prefix: prefix}, markers, related) do
    assert %{rows: [[^markers]]} =
             SQL.query!(Repo, ~s|SELECT count(*) FROM "#{prefix}".replay_hook_writes|, [])

    assert %{rows: [[^related]]} =
             SQL.query!(Repo, ~s|SELECT count(*) FROM "#{prefix}".replay_related|, [])
  end

  defp assert_committed_writes(%{reader: reader, prefix: prefix}, markers, related) do
    refute Repo.in_transaction?()

    assert %{rows: [[^markers, ^related]]} =
             SQL.query!(reader, ~s|SELECT
               (SELECT count(*) FROM "#{prefix}".replay_hook_writes),
               (SELECT count(*) FROM "#{prefix}".replay_related)|, [])
  end
end
