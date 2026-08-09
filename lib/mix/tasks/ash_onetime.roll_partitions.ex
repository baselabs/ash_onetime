defmodule Mix.Tasks.AshOnetime.RollPartitions do
  @moduledoc """
  Creates the next batch of monthly `ash_onetime_response_payloads` range partitions.

      mix ash_onetime.roll_partitions --repo MyApp.Repo
      mix ash_onetime.roll_partitions --repo MyApp.Repo --prefix tenant_1 --months 6

  Forward partition creation keeps retention bounded past the install window: without it,
  payloads whose `response_partition` falls outside the generated window route to the `_default`
  partition and are never dropped, silently defeating bounded retention. Idempotent and
  concurrency-safe (advisory-locked). Schedule it via `AshOnetime.Oban.PartitionWorker` or a
  cron cadence; the operator picks `--months` to stay ahead of their retention horizon.
  """

  use Mix.Task

  alias AshOnetime.Store
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Store.Result

  @shortdoc "Creates forward monthly ash_onetime response partitions"
  @switches [repo: :string, prefix: :string, months: :integer]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid ash_onetime roll_partitions arguments")

    repo = parse_repo!(options[:repo])
    months = options[:months] || 3

    unless months in 1..24,
      do: Mix.raise("--months must be from 1 through 24")

    target = Postgres.for_repo(repo, parse_prefix!(options[:prefix]))

    case Store.roll_partitions(target, months) do
      {:ok, %{partitions_created: count}} ->
        Mix.shell().info("Created #{count} response_payloads partition(s)")
        :ok

      %Result{} ->
        Mix.raise("ash_onetime roll_partitions failed")
    end
  end

  defp parse_repo!(nil), do: Mix.raise("--repo is required")

  defp parse_repo!(name) when is_binary(name) do
    repo = Module.safe_concat(String.split(name, ".", trim: true))

    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo
    else
      Mix.raise("repo is not available")
    end
  rescue
    ArgumentError -> Mix.raise("repo is not available")
  end

  defp parse_prefix!(nil), do: nil

  defp parse_prefix!(prefix) when is_binary(prefix) and byte_size(prefix) in 1..63,
    do: prefix

  defp parse_prefix!(_prefix), do: Mix.raise("invalid --prefix")
end
