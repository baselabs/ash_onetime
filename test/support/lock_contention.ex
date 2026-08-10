defmodule AshOnetime.Test.LockContention do
  @moduledoc false

  # Forces a Store operation into REAL :lock_timeout contention for the L5 worker error-tuple
  # tests. A holder process acquires the conflicting lock in its own real (sandbox: false)
  # transaction and holds it; the worker (in the test process's separate sandbox:false
  # transaction) blocks against it and times out. Two real connections is what makes the
  # contention observable.
  #
  # Robustness (per cross-vendor review): every acquired holder is released and every session
  # GUC is reset on EVERY path — including the failure path where the worker assertion raised
  # or the holder never signaled readiness. The holder TRAPS EXITS so a `:shutdown` signal runs
  # its `after` (Sandbox.stop_owner, returning the connection); `:kill` is never used because it
  # would skip the after and leak the checked-out connection + lock to the pool.
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Spawns a holder that runs `sql`/`params` (a lock-acquiring statement) in a real transaction
  and HOLDS the transaction open until released. Sends `{:held, holder_pid}` to `parent` once
  the lock is acquired. The holder traps exits so a shutdown signal still runs its teardown.
  """
  def acquire(parent, sql, params \\ []) do
    spawn(fn ->
      Process.flag(:trap_exit, true)
      owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)

      try do
        {:ok, _} =
          Repo.transaction(fn ->
            {:ok, _} = SQL.query(Repo, sql, params)
            send(parent, {:held, self()})

            receive do
              :release -> :ok
              {:EXIT, _, _} -> :ok
            end
          end)
      after
        Sandbox.stop_owner(owner)
      end
    end)
  end

  @doc """
  Releases a holder. Sends `:release` and waits for the holder to tear down (its `after` runs
  `Sandbox.stop_owner`, returning the connection + releasing the lock). If it does not respond
  within 2s, sends a trap-able `:shutdown` (the holder traps exits, so its `after` STILL runs);
  `:kill` is deliberately avoided because it skips the `after` and leaks the connection.
  """
  def release(holder) when is_pid(holder) do
    ref = Process.monitor(holder)
    send(holder, :release)

    receive do
      {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
    after
      2_000 ->
        Process.exit(holder, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  @doc """
  Runs `fun` against a contended lock. Optionally sets a short session `lock_timeout` (for
  operations that do not set their own) and ALWAYS resets it in the `after`. The acquired
  holder is tracked through the process dictionary so the `after` can release it even when
  `fun` raised or the holder never signaled readiness — no holder and no GUC ever leak to the
  pool on any path.

  Options: `:lock_timeout_ms` (the session lock_timeout to set/reset around the contention).
  """
  def with_contention(lock_sql, lock_params \\ [], opts \\ [], fun) do
    lock_timeout_ms = Keyword.get(opts, :lock_timeout_ms)
    holder_key = {__MODULE__, :holder}
    Process.put(holder_key, nil)

    try do
      if lock_timeout_ms do
        {:ok, _} = SQL.query(Repo, "SET lock_timeout = #{lock_timeout_ms}")
      end

      holder = acquire(self(), lock_sql, lock_params)
      Process.put(holder_key, holder)

      receive do
        {:held, ^holder} -> :ok
      after
        2_000 -> raise "lock holder did not acquire the conflicting lock within 2s"
      end

      fun.()
    after
      if holder = Process.get(holder_key), do: release(holder)
      if lock_timeout_ms, do: {:ok, _} = SQL.query(Repo, "RESET lock_timeout")
    end
  end
end
