defmodule AshOnetime.Test.Repo do
  @moduledoc false

  use AshPostgres.Repo, otp_app: :ash_onetime

  alias AshOnetime.Test.DeliveryFacts.Observer
  alias AshOnetime.Test.DeliveryGuarded.Consumer
  alias AshOnetime.Test.Postgres

  @impl AshPostgres.Repo
  def installed_extensions, do: ["ash-functions"]

  @impl AshPostgres.Repo
  def min_pg_version do
    %Version{major: Postgres.contract().major, minor: 0, patch: 0}
  end

  # Consumer code at `repo.prepare_query/3` (§2.7.4): it sees the authorization query
  # and the subject context Ash put on it. It acts only when a delivery test planned it.
  @impl Ecto.Repo
  def prepare_query(:all, query, opts) do
    context = query |> Map.get(:__ash_bindings__, %{}) |> Map.get(:context)
    scope = %{context: context || %{}, tenant: query.prefix}
    Consumer.run(:prepare_query, nil, context, scope)
    {query, opts}
  end

  def prepare_query(_operation, query, opts), do: {query, opts}

  # Consumer code at the data layer's transaction begin (F7): it receives the reason Ash
  # passes, the generic action's input included. It notes only when a facts test watches.
  @impl AshPostgres.Repo
  def on_transaction_begin(reason),
    do: Observer.note({:transaction_begin, reason})
end
