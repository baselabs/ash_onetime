defmodule AshOnetime.Test.RealConnection do
  @moduledoc """
  Scoped real (non-transactional) database connections for contention tests.

  `with_connection/1` checks a connection out to the CALLING process — manual-mode
  `Sandbox.checkout(repo, sandbox: false)` — and checks it back in when the callback
  returns. Task processes that call it each hold their own independent real
  connection, which is what the contention tests mean by "separate real connections".

  This replaces the previous `Sandbox.start_owner!/2` proxy-owner pattern. That
  pattern's teardown is asynchronous with respect to `stop_owner/1`: the owner agent
  dies, the ownership proxy observes the agent's `:DOWN`, the proxy stops, and only
  then does the ownership manager drop the caller's `{:allowed, _}` entry. A second
  `start_owner!/2` in the same process that wins the race against that cleanup chain
  crashes with `{:badmatch, {:already, :allowed}}` at the `:ok = allow(repo, self(),
  parent)` line inside `start_owner!` — the RollContentionTest full-suite flake
  (deterministic on an immediate back-to-back pair; real work between owners usually
  covers the cleanup window, hence the ~10%-per-run rate under suite load). A
  `checkin/1` in the calling process, by contrast, removes the caller's own entry
  synchronously inside the manager call, so there is no stale allowance to collide
  with. The regression tripwire in `RollContentionTest` pins the class.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @spec with_connection(module(), (-> result)) :: result when result: var
  def with_connection(repo \\ AshOnetime.Test.Repo, callback) do
    :ok = Sandbox.checkout(repo, sandbox: false)

    try do
      callback.()
    after
      Sandbox.checkin(repo)
    end
  end
end
