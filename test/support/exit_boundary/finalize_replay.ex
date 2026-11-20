defmodule AshOnetime.Test.ExitBoundary.FinalizeReplay do
  @moduledoc false
  alias AshOnetime.{Response, Store}
  alias AshOnetime.Store.{Claim, Postgres, Result}
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  # Complete the already locked, real claim while the peer callback is running.
  # Finalization then sees that authoritative completion after Delivery.seal.
  def complete(subject, operation_key) do
    prefix = subject.to_tenant

    %{columns: columns, rows: [row]} =
      SQL.query!(
        Repo.get_dynamic_repo(),
        ~s(SELECT * FROM "#{prefix}".ash_onetime_idempotency_claims WHERE id = $1::uuid),
        [Ecto.UUID.dump!(operation_key)]
      )

    fields =
      Map.new(Enum.zip(columns, row), fn {key, value} -> {String.to_existing_atom(key), value} end)

    fields =
      fields
      |> Map.take(Map.keys(Map.from_struct(struct(Claim))))
      |> Map.put(:id, operation_key)
      |> Map.put(:strategy, :idempotency)
      |> Map.update!(:state, &String.to_existing_atom/1)

    claim = struct!(Claim, fields)
    protection = AshOnetime.Resource.Info.protection(subject.resource, subject.action.name)
    trusted = %{tenant: prefix, limits: protection.limits}

    trusted =
      if subject.action.type == :destroy,
        do: Map.put(trusted, :return_destroyed?, true),
        else: trusted

    {:ok, contract} =
      Response.contract(subject.resource, subject.action.name, protection.response, trusted)

    result =
      case subject do
        %Ash.ActionInput{} ->
          7

        %Ash.Changeset{} ->
          {:ok, record} = Ash.Changeset.apply_attributes(subject)
          record
      end

    {:ok, encoded} = Response.encode(result, contract, [])

    %Result{status: :complete} =
      Store.complete_external(
        Postgres.for_repo(Repo, prefix),
        claim,
        encoded.codec,
        encoded.digest,
        encoded.payload
      )

    :ok
  end
end
