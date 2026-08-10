defmodule AshOnetime.Cache.Ets do
  @moduledoc """
  A reference ETS adapter for the optional completed-response cache.

  Bounded and TTL-aware. `:ets` has no native TTL, so each entry carries an expiry
  monotonic-time deadline and `get/1` rejects expired entries (and lazily deletes them). A
  max-entries cap bounds steady-state memory; when the cap is reached `put/3` evicts the
  single oldest-by-deadline entry before inserting, which keeps the hot set resident under
  churn without a background sweeper.

  The adapter is NOT admission authority — `AshOnetime` validates every field of a returned
  entry against the authoritative PostgreSQL claim before using the payload (see
  `AshOnetime.Cache`). Treat every entry as untrusted.

  ## Supervision

  The ETS table is owned by a GenServer started via `start_link/1`. Add it to your supervision
  tree (it owns the table; if it terminates the table is destroyed, which is safe — the cache
  is optional and a miss falls through to PostgreSQL):

      children = [
        # ...your repo...
        {AshOnetime.Cache.Ets, max_entries: 10_000}
      ]

  Then configure it as the cache module:

      config :ash_onetime, cache: AshOnetime.Cache.Ets

  The table is named `__MODULE__` (one ETS cache per VM). A multi-instance deployment (e.g.
  one cache per tenant prefix) wraps this module behind a per-instance module so each gets its
  own `__MODULE__`-named table; the reference adapter is single-instance by design.

  ## Options

    * `:max_entries` — the bounded cap; `put/3` evicts the oldest-by-deadline entry when the
      cap is reached before inserting (default 10_000). The cap bounds entry COUNT only — the
      per-entry byte ceiling is enforced upstream by `AshOnetime.Cache` (`max_entry_bytes`).

  ## Limitations

  This is a reference adapter tuned for simplicity and correctness, not throughput: the
  eviction is a single oldest-by-deadline scan, and expired entries are reaped lazily on
  `get/1` rather than by a background sweeper. A high-throughput deployment should reach for
  Redis or a dedicated cache with sampled-LRU eviction and active expiry; this adapter exists
  so the cache-degradation path in `AshOnetime.Cache` is reachable without a third-party
  dependency.
  """

  @behaviour AshOnetime.Cache
  @behaviour GenServer

  alias AshOnetime.Cache.Entry

  @table __MODULE__
  @default_max_entries 10_000

  # The table stores entries as `{key, %Entry{}, expiry_monotonic}` plus a `{:__config__, n}`
  # row carrying the max-entries cap. The owning GenServer is the table owner; `:public` lets
  # the cache callbacks (called from arbitrary admission processes) read/write without a
  # message round-trip, while `read_concurrency` tunes for the cache access pattern.
  @table_options [:set, :public, :named_table, {:read_concurrency, true}]

  ## Public API

  @doc """
  A supervisor child specification for the owning GenServer.

  ## Options

    * `:max_entries` — the bounded entry cap (default 10_000).

  Add it to your supervision tree:

      children = [
        {AshOnetime.Cache.Ets, max_entries: 10_000}
      ]
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts the owning GenServer for the ETS table.

  ## Options

    * `:max_entries` — the bounded entry cap (default 10_000).

  Returns `{:ok, pid}` or `{:error, {:already_started, pid}}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    GenServer.start_link(__MODULE__, max_entries, name: @table)
  end

  @doc """
  Returns the configured max-entries cap.
  """
  @spec max_entries() :: non_neg_integer()
  def max_entries do
    case :ets.lookup(@table, :__config__) do
      [{:__config__, max_entries}] -> max_entries
      [] -> @default_max_entries
    end
  end

  @doc """
  Drops every entry from the cache (the table and config are retained).

  Safe to call while the cache is serving; `get/1` calls during a wipe may race with the
  delete and return `:miss`, which is always safe (a miss falls through to PostgreSQL).
  """
  @spec clear() :: :ok
  def clear do
    try do
      :ets.foldl(
        fn
          {:__config__, _}, acc -> acc
          {key, _entry, _expiry}, _acc -> :ets.delete(@table, key)
        end,
        :ok,
        @table
      )
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  ## AshOnetime.Cache callbacks

  @impl AshOnetime.Cache
  def get(key) when is_binary(key) do
    try do
      case :ets.lookup(@table, key) do
        [{^key, %Entry{} = entry, expiry}] ->
          if expiry > System.monotonic_time(:second) do
            {:ok, entry}
          else
            # Lazy expiry: the entry's deadline passed. Delete and miss.
            :ets.delete(@table, key)
            :miss
          end

        [] ->
          :miss
      end
    catch
      :error, :badarg -> {:error, :unavailable}
    end
  end

  @impl AshOnetime.Cache
  def put(key, %Entry{} = entry, ttl_seconds)
      when is_binary(key) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    try do
      maybe_evict()
      expiry = System.monotonic_time(:second) + ttl_seconds
      :ets.insert(@table, {key, entry, expiry})
      :ok
    catch
      :error, :badarg -> {:error, :unavailable}
    end
  end

  def put(_key, _entry, _ttl_seconds), do: {:error, :invalid_entry}

  @impl AshOnetime.Cache
  def delete(key) when is_binary(key) do
    try do
      :ets.delete(@table, key)
      :ok
    catch
      :error, :badarg -> :ok
    end
  end

  ## GenServer callbacks

  @impl GenServer
  def init(max_entries) do
    :ets.new(@table, @table_options)
    :ets.insert(@table, {:__config__, max_entries})
    {:ok, %{max_entries: max_entries}}
  end

  @impl GenServer
  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    # The table is owned by this process and destroyed automatically on terminate. Nothing to
    # do; the clause documents the ownership invariant explicitly.
    :ok
  end

  ## Eviction

  defp maybe_evict do
    case {entry_count(), max_entries()} do
      {count, cap} when count >= cap and cap > 0 -> evict_oldest()
      _ -> :ok
    end
  end

  defp entry_count do
    try do
      # Subtract 1 for the :__config__ row that is not a cache entry.
      :ets.info(@table, :size) - 1
    catch
      :error, :badarg -> 0
    end
  end

  defp evict_oldest do
    # A single oldest-by-deadline entry. Under sustained churn this is O(n) per evicting put,
    # which is the documented trade-off of the reference adapter (a high-throughput deployment
    # should reach for a dedicated cache). The fold is bounded by the cap.
    oldest =
      :ets.foldl(
        fn
          {:__config__, _}, acc ->
            acc

          {key, _entry, expiry}, nil ->
            {key, expiry}

          {key, _entry, expiry}, {_acc_key, acc_expiry} when expiry < acc_expiry ->
            {key, expiry}

          _row, acc ->
            acc
        end,
        nil,
        @table
      )

    case oldest do
      {key, _expiry} -> :ets.delete(@table, key)
      nil -> :ok
    end
  end
end
