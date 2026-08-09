if Code.ensure_loaded?(Oban.Worker) do
  defmodule AshOnetime.Oban.PartitionWorker do
    @moduledoc """
    Optional Oban entry point for forward response-partition creation, mirroring
    `mix ash_onetime.roll_partitions`. Schedule it ahead of the retention horizon (e.g. daily or
    weekly) so payloads never route to the `_default` partition; without it, bounded retention
    silently degrades past the install window.
    """

    use Oban.Worker, queue: :ash_onetime_cleanup, max_attempts: 3

    alias AshOnetime.Store
    alias AshOnetime.Store.Postgres

    @impl Oban.Worker
    def perform(%Oban.Job{args: arguments}) when is_map(arguments) do
      with {:ok, repo} <- repo(arguments["repo"]),
           {:ok, prefix} <- prefix(arguments["prefix"]),
           {:ok, months} <- bounded(arguments["months"], 3, 1, 24),
           {:ok, _result} <-
             Store.roll_partitions(Postgres.for_repo(repo, prefix), months) do
        :ok
      else
        {:error, :invalid_arguments} -> {:discard, :invalid_arguments}
        _store_failure -> {:error, :roll_partitions_failed}
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
