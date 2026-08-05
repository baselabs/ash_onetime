defmodule AshOnetime.Test.ReplayChanges.Pure do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: changeset

  def replay_safety(_opts), do: :pure

  def replay_capabilities(_opts),
    do: %{notifications: false, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.Test.ReplayChanges.Aware do
  @moduledoc false
  use Ash.Resource.Change

  alias Ecto.Adapters.SQL

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn final_changeset, result ->
      if observer = Keyword.get(opts, :observer) do
        send(observer, {:replay_seen, AshOnetime.Admission.replay?(final_changeset)})
      end

      if opts[:transaction_ledger?] and not AshOnetime.Admission.replay?(final_changeset) do
        prefix = final_changeset.to_tenant

        SQL.query!(
          AshOnetime.Test.Repo,
          """
          INSERT INTO "#{prefix}"."ash_onetime_action_observations"
            (kind, claim_id, backend_pid, transaction_id, prefix)
          SELECT 'business', id, pg_backend_pid(), txid_current(), $1
          FROM "#{prefix}"."ash_onetime_idempotency_claims"
          ORDER BY inserted_at DESC
          LIMIT 1
          """,
          [prefix]
        )
      end

      {:ok, result}
    end)
  end

  def replay_safety(_opts), do: :replay_aware

  def replay_capabilities(opts) do
    %{
      notifications: Keyword.get(opts, :notifications?, false),
      effects: Keyword.get(opts, :transaction_ledger?, false),
      around_action: false,
      marker: :consumed
    }
  end
end
