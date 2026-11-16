if Code.ensure_loaded?(Oban.Worker) do
  defmodule AshOnetime.Oban.CleanupWorker do
    @moduledoc """
    Optional Oban entry point for the same bounded cleanup operation as `mix ash_onetime.prune`.
    """

    use Oban.Worker, queue: :ash_onetime_cleanup, max_attempts: 3

    alias AshOnetime.Store
    alias AshOnetime.Store.Postgres
    alias AshOnetime.Store.Result

    # Maintenance retries use linear backoff with up to 30 seconds of jitter.
    # The first two delays are [30,60) and [60,90) seconds.
    # Delay caps at 120 seconds if max_attempts increases.
    # Spacing gives contended DDL locks time to clear.
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
           {:ok, partition_limit} <- bounded(arguments["partition_limit"], 8, 0, 128),
           {:ok, _counts} <-
             Store.cleanup(Postgres.for_repo(repo, prefix), batch_size, partition_limit) do
        :ok
      else
        {:error, :invalid_arguments} ->
          {:discard, :invalid_arguments}

        # Store.cleanup returns a bare %Result{} on failure (not {:error, %Result{}}). Embed
        # the Result.reason so Oban's job error carries the distinguishable cause past exhaustion.
        %Result{reason: reason} ->
          {:error, {:cleanup_failed, reason}}
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
