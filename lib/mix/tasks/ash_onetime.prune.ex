defmodule Mix.Tasks.AshOnetime.Prune do
  @moduledoc """
  Removes one bounded batch of expired claims and empty response partitions.

      mix ash_onetime.prune --repo MyApp.Repo
      mix ash_onetime.prune --repo MyApp.Repo --prefix tenant_1 --batch-size 500
  """

  use Mix.Task

  alias AshOnetime.Store
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Store.Result

  @shortdoc "Prunes one bounded batch of expired ash_onetime state"
  @switches [repo: :string, prefix: :string, batch_size: :integer, partition_limit: :integer]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid ash_onetime prune arguments")

    repo = parse_repo!(options[:repo])
    batch_size = options[:batch_size] || 500
    partition_limit = options[:partition_limit] || 8

    unless batch_size in 1..10_000,
      do: Mix.raise("--batch-size must be from 1 through 10000")

    unless partition_limit in 0..128,
      do: Mix.raise("--partition-limit must be from 0 through 128")

    target = Postgres.for_repo(repo, parse_prefix!(options[:prefix]))

    case Store.cleanup(target, batch_size, partition_limit) do
      {:ok, counts} ->
        Mix.shell().info(
          "Pruned idempotency=#{counts.idempotency} nonce=#{counts.nonce} " <>
            "payload_partitions=#{counts.payload_partitions}"
        )

        :ok

      %Result{} ->
        Mix.raise("ash_onetime cleanup failed")
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
