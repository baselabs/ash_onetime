defmodule AshOnetime.Test.Cache do
  @moduledoc false

  @behaviour AshOnetime.Cache
  @table __MODULE__

  def start do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _table -> @table
    end

    reset()
  end

  def reset do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:mode, :normal})
    :ok
  end

  def mode(mode) do
    ensure_table!()
    :ets.insert(@table, {:mode, mode})
    :ok
  end

  def poison(entry) do
    ensure_table!()
    :ets.insert(@table, {:poison, entry})
    :ok
  end

  def entries do
    ensure_table!()

    @table
    |> :ets.tab2list()
    |> Enum.filter(&match?({{:entry, _key}, _entry, _ttl}, &1))
  end

  @impl AshOnetime.Cache
  def get(key) do
    case lookup(:mode, :normal) do
      :timeout -> Process.sleep(5_000)
      :circuit_open -> {:error, :circuit_open}
      :corrupt -> {:ok, :not_a_cache_entry}
      :normal -> get_entry(key)
    end
  end

  @impl AshOnetime.Cache
  def put(key, entry, ttl_seconds) do
    case lookup(:mode, :normal) do
      :circuit_open ->
        {:error, :circuit_open}

      :timeout ->
        Process.sleep(5_000)

      _mode ->
        :ets.insert(@table, {{:entry, key}, entry, ttl_seconds})
        :ok
    end
  end

  @impl AshOnetime.Cache
  def delete(key) do
    :ets.delete(@table, {:entry, key})
    :ok
  end

  defp get_entry(key) do
    case :ets.lookup(@table, :poison) do
      [{:poison, entry}] ->
        {:ok, entry}

      [] ->
        case :ets.lookup(@table, {:entry, key}) do
          [{{:entry, ^key}, entry, _ttl}] -> {:ok, entry}
          [] -> :miss
        end
    end
  end

  defp lookup(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp ensure_table! do
    if :ets.whereis(@table) == :undefined, do: start()
    :ok
  end
end
