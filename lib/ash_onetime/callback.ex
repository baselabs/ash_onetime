defmodule AshOnetime.Callback do
  @moduledoc false

  alias AshOnetime.Error

  @default_timeout 5_000
  @maximum_timeout 30_000
  @messages %{
    invalid_signature: "token signature is invalid",
    key_unusable: "token key is unusable",
    custody_unavailable: "key custody is unavailable",
    custody_timeout: "key custody timed out",
    custody_contract_violation: "key custody violated its callback contract",
    outside_window: "token is outside its acceptance window",
    algorithm_mismatch: "token algorithm does not match expectation",
    namespace_mismatch: "token namespace does not match expectation",
    verifier_contract_violation: "verifier or minter violated its callback contract",
    verification_failed: "verification failed",
    verification_timeout: "verification timed out"
  }

  def error(code), do: Error.new(code, Map.fetch!(@messages, code))

  def timeout(value \\ nil) do
    configured = Application.get_env(:ash_onetime, :callback_timeout_ms, @default_timeout)
    bounded_timeout(value || configured)
  end

  def run(callback, timeout \\ nil) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(AshOnetime.TaskSupervisor, fn ->
        worker = self()

        {:ok, _monitor} =
          Task.Supervisor.start_child(AshOnetime.TaskSupervisor, fn ->
            watch_owner(owner, worker)
          end)

        invoke(callback)
      end)

    try do
      case Task.yield(task, timeout(timeout)) do
        {:ok, {:returned, result}} ->
          {:ok, result}

        {:ok, :failed} ->
          {:error, :contract_violation}

        {:exit, _reason} ->
          {:error, :contract_violation}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :deadline}
      end
    after
      Process.demonitor(task.ref, [:flush])
      flush_reply(task.ref)
    end
  end

  # async_nolink monitors its owner only until execution starts. Keep the
  # lifetime monitor outside the callback so killing an outer verifier cannot
  # strand a nested custody worker that is blocked in its own callback.
  defp watch_owner(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp invoke(callback) do
    {:returned, callback.()}
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp bounded_timeout(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_timeout)

  defp bounded_timeout(_), do: @default_timeout

  defp flush_reply(reference) do
    receive do
      {^reference, _reply} -> :ok
    after
      0 -> :ok
    end
  end
end
