defmodule AshOnetime.Test.ReplayRelationships.BrokenPure do
  @moduledoc false
  use Ash.Resource.Change

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &add_relationship_changes/1)
  end

  defp add_relationship_changes(pending) do
    if Process.get({__MODULE__, :break?}) do
      SQL.query!(
        Repo,
        ~s|INSERT INTO "#{pending.to_tenant}".replay_hook_writes (label) VALUES ('hook')|,
        []
      )

      pending =
        Ash.Changeset.manage_relationship(pending, :children, %{label: "late"}, type: :create)

      if Process.get({__MODULE__, :break?}) == :partial do
        Ash.Changeset.manage_relationship(pending, :children, %{id: Ecto.UUID.generate()},
          type: :append,
          on_lookup: :ignore,
          on_no_match: :error
        )
      else
        pending
      end
    else
      pending
    end
  end

  def replay_safety(_opts), do: :pure

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.Test.ReplayRelationships.Aware do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn pending, result ->
      send(self(), {:relationship_replay_hook, AshOnetime.Admission.replay?(pending)})
      {:ok, Ash.Resource.unload_many(result, [:children, :owner])}
    end)
  end

  def replay_safety(_opts), do: :replay_aware

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: true, around_action: false, marker: :consumed}
end

defmodule AshOnetime.Test.ReplayRelationships.ResultAllowed do
  @moduledoc false
  use Ash.Policy.Check

  alias AshOnetime.Test.Repo

  @impl true
  def describe(_opts), do: "the returned record is allowed"

  @impl true
  def strict_check(_actor, _context, _opts), do: {:ok, :unknown}

  @impl true
  def check(_actor, records, _context, _opts) do
    send(
      self(),
      {:relationship_result_check, Enum.map(records, & &1.id), Repo.in_transaction?()}
    )

    if Process.get({__MODULE__, :refuse?}), do: [], else: records
  end
end
