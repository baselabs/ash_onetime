if Code.ensure_loaded?(Oban.Worker) do
  defmodule AshOnetime.Oban.ReapWorker do
    @moduledoc """
    Optional Oban entry point for the same bounded reap operation as `mix ash_onetime.reap`.

    Deletes abandoned `processing` idempotency recovery points past an abandonment horizon.
    Schedule it far less frequently than `AshOnetime.Oban.CleanupWorker`.
    """

    use Oban.Worker, queue: :ash_onetime_reap, max_attempts: 3

    alias AshOnetime.Store
    alias AshOnetime.Store.Postgres

    # Mirrors the migration's @abandonment_floor_seconds; the reap function re-enforces it.
    @abandonment_floor_seconds 86_400
    @max_abandonment_seconds 2_147_483_647

    # Bounded jittered backoff — see CleanupWorker for the rationale. The reaper bounds
    # steady-state growth of abandoned processing claims; a transient failure should retry
    # within minutes rather than lengthening the reap cadence.
    @base_backoff_seconds 30
    @max_backoff_seconds 120

    @impl Oban.Worker
    def backoff(%Oban.Job{attempt: attempt}) do
      delay = @base_backoff_seconds * attempt + :rand.uniform(@base_backoff_seconds) - 1
      min(delay, @max_backoff_seconds)
    end

    @impl Oban.Worker
    def perform(%Oban.Job{args: arguments}) when is_map(arguments) do
      with {:ok, repo} <- repo(arguments["repo"]),
           {:ok, prefix} <- prefix(arguments["prefix"]),
           {:ok, batch_size} <- bounded(arguments["batch_size"], 500, 1, 10_000),
           {:ok, abandonment_seconds} <-
             bounded(
               arguments["abandonment_seconds"],
               604_800,
               @abandonment_floor_seconds,
               @max_abandonment_seconds
             ),
           {:ok, _reaped} <-
             Store.reap(Postgres.for_repo(repo, prefix), batch_size, abandonment_seconds) do
        :ok
      else
        {:error, :invalid_arguments} -> {:discard, :invalid_arguments}
        _store_failure -> {:error, :reap_failed}
      end
    end

    def perform(_job), do: {:discard, :invalid_arguments}

    defp repo(name) when is_binary(name) do
      module = Module.safe_concat(String.split(name, ".", trim: true))

      if Code.ensure_loaded?(module) and function_exported?(module, :config, 0),
        do: {:ok, module},
        else: {:error, :invalid_arguments}
    rescue
      ArgumentError -> {:error, :invalid_arguments}
    end

    defp repo(_name), do: {:error, :invalid_arguments}

    defp prefix(nil), do: {:ok, nil}
    defp prefix(value) when is_binary(value) and byte_size(value) in 1..63, do: {:ok, value}
    defp prefix(_value), do: {:error, :invalid_arguments}

    defp bounded(nil, default, _minimum, _maximum), do: {:ok, default}

    defp bounded(value, _default, minimum, maximum)
         when is_integer(value) and value >= minimum and value <= maximum,
         do: {:ok, value}

    defp bounded(_value, _default, _minimum, _maximum), do: {:error, :invalid_arguments}
  end
end
