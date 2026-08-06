defmodule Mix.Tasks.AshOnetime.Reap do
  @moduledoc """
  Removes one bounded batch of abandoned `processing` idempotency recovery points past an
  abandonment horizon.

      mix ash_onetime.reap --repo MyApp.Repo
      mix ash_onetime.reap --repo MyApp.Repo --prefix tenant_1 --abandonment-seconds 1209600

  A recovery point is reaped only when it is older than `--abandonment-seconds`, older than the
  migration's hard 1-day floor, and past its own retention horizon — the delete guard re-enforces
  all three. `--abandonment-seconds` must be at least the 1-day floor (86400). Schedule this far
  less frequently than `mix ash_onetime.prune`.
  """

  use Mix.Task

  alias AshOnetime.Store
  alias AshOnetime.Store.Postgres
  alias AshOnetime.Store.Result

  @shortdoc "Reaps one bounded batch of abandoned ash_onetime processing recovery points"
  @switches [repo: :string, prefix: :string, batch_size: :integer, abandonment_seconds: :integer]

  # Mirrors the migration's @abandonment_floor_seconds; the reap function re-enforces it.
  @abandonment_floor_seconds 86_400
  @max_abandonment_seconds 2_147_483_647

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid ash_onetime reap arguments")

    repo = parse_repo!(options[:repo])
    batch_size = options[:batch_size] || 500
    abandonment_seconds = options[:abandonment_seconds] || 604_800

    unless batch_size in 1..10_000,
      do: Mix.raise("--batch-size must be from 1 through 10000")

    unless abandonment_seconds in @abandonment_floor_seconds..@max_abandonment_seconds,
      do:
        Mix.raise("--abandonment-seconds must be at least #{@abandonment_floor_seconds} (1 day)")

    target = Postgres.for_repo(repo, parse_prefix!(options[:prefix]))

    case Store.reap(target, batch_size, abandonment_seconds) do
      {:ok, reaped} ->
        Mix.shell().info("Reaped idempotency=#{reaped}")
        :ok

      %Result{} ->
        Mix.raise("ash_onetime reap failed")
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
