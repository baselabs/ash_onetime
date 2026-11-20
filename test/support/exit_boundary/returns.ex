defmodule AshOnetime.Test.ExitBoundary.Returns do
  @moduledoc false
  alias AshOnetime.Delivery

  # The public deliver/2 contract, independent of its private normalizer.
  def delivered({:error, _} = error, _type, _opts, _delivery), do: error
  def delivered(:ok, _type, _opts, delivery), do: {:ok, nil, delivery}
  def delivered({:ok, result, notifications}, _type, _opts, delivery),
    do: {:ok, result, notifications, delivery}
  def delivered({:ok, value}, :destroy, opts, delivery) do
    if opts[:return_notifications?] && !opts[:return_destroyed?],
      do: {:ok, nil, value, delivery}, else: {:ok, value, delivery}
  end
  def delivered({:ok, result}, _type, _opts, delivery), do: {:ok, result, delivery}

  def delivery(row, values) do
    outcome = case row.branch do
      branch when branch in [:replay, :finalize_replay] -> :replayed
      branch when branch in [:recovered, :unknown] -> :recovered
      _ -> :executed
    end
    %Delivery{outcome: outcome, values: if(outcome == :executed, do: values, else: %{})}
  end

  def raw(side) do
    Enum.find_value(side.run.events, fn
      %{event: {_, :call, {Delivery, :normalize, [raw, _type, _opts]}}} -> {:found, raw}
      _ -> nil
    end)
  end
end
