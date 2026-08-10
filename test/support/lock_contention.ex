defmodule AshOnetime.Test.LockContention do
  @moduledoc false

  # Spawns a process that acquires a lock inside a real (sandbox: false) transaction and
  # HOLDS it (transaction left open) until :release is sent. Used by the L5 worker error-tuple
  # tests to force a Store operation into real :lock_timeout contention — the worker runs in
  # the test process's own sandbox:false connection and blocks against the lock held here.
  #
  # The holder runs in a SEPARATE process with its own Sandbox owner so it owns a distinct
  # connection — two real connections is what makes the contention observable.
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Spawns a lock holder. `sql`/`params` is a statement that ACQUIRES the conflicting lock
  (e.g. `SELECT pg_advisory_xact_lock($1)` or `LOCK TABLE ... IN ACCESS EXCLUSIVE MODE`).
  Sends `{:held, holder_pid}` to `parent` once the lock is acquired, then blocks until
  `:release` is sent to the holder. Returns the holder pid.
  """
  def acquire(parent, sql, params \\ []) do
    spawn(fn ->
      owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)

      try do
        Repo.transaction(fn ->
          {:ok, _} = SQL.query(Repo, sql, params)
          send(parent, {:held, self()})
          receive(do: (:release -> :ok))
        end)
      after
        Sandbox.stop_owner(owner)
      end
    end)
  end

  @doc """
  Releases a holder and waits for it to tear down (so its connection/lock are reclaimed).
  Safe to call from an `after` block; harmless if the holder already exited.
  """
  def release(holder) when is_pid(holder) do
    ref = Process.monitor(holder)

    send(holder, :release)

    receive do
      {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
    after
      2_000 -> Process.exit(holder, :kill)
    end
  end
end
