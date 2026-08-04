defmodule Mix.Tasks.AshOnetime.Gen.Migrations do
  @moduledoc """
  Generates the PostgreSQL objects required by `ash_onetime`.

      mix ash_onetime.gen.migrations --repo MyApp.Repo
      mix ash_onetime.gen.migrations --repo MyApp.Repo --claims hash --claim-partitions 8

  Use `--tenants` to write to the repo tenant migration directory.
  """

  use Mix.Task

  import Mix.Generator, only: [create_directory: 1, create_file: 2]

  @shortdoc "Generates ash_onetime PostgreSQL migrations"
  @collision_constraint "UNIQUE (operation_hash, scope_hash, key_hash)"
  @cleanup_comparator ">"
  @cleanup_delete_predicate "claims.operation_hash = candidates.operation_hash AND claims.id = candidates.id"
  @switches [
    repo: :string,
    claims: :string,
    claim_partitions: :integer,
    tenants: :boolean,
    migrations_path: :string
  ]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid ash_onetime migration generator arguments")
    end

    repo = parse_repo!(options[:repo])
    hash_partitions = parse_claim_partitioning!(options)
    path = migration_path(repo, options)
    create_directory(path)
    refuse_existing!(path)

    module = Module.concat([repo, Migrations, InstallAshOnetime])
    response_partitions = response_partitions(Date.utc_today())

    template_name = if hash_partitions, do: "hash_partitioned.exs", else: "install.exs"

    source =
      template_name
      |> template_path()
      |> EEx.eval_file(
        module: module,
        collision_constraint: @collision_constraint,
        cleanup_comparator: @cleanup_comparator,
        cleanup_delete_predicate: @cleanup_delete_predicate,
        hash_partitions: hash_partitions,
        response_partitions: response_partitions
      )

    file = Path.join(path, "#{timestamp()}_install_ash_onetime.exs")
    create_file(file, source)
    Mix.shell().info("Generated #{file}")
    file
  end

  defp parse_repo!(nil), do: Mix.raise("--repo is required")

  defp parse_repo!(repo_name) do
    repo = repo_name |> String.split(".") |> Module.concat()

    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo
    else
      Mix.raise("repo #{repo_name} is not available")
    end
  end

  defp parse_claim_partitioning!(options) do
    case {options[:claims], options[:claim_partitions]} do
      {nil, nil} -> nil
      {"plain", nil} -> nil
      {"hash", count} when is_integer(count) -> validate_partition_count!(count)
      {"hash", nil} -> Mix.raise("--claims hash requires --claim-partitions")
      {nil, _count} -> Mix.raise("--claim-partitions requires --claims hash")
      {_other, _count} -> Mix.raise("--claims must be hash when provided")
    end
  end

  defp validate_partition_count!(count)
       when count >= 2 and count <= 64 and Bitwise.band(count, count - 1) == 0,
       do: count

  defp validate_partition_count!(_count) do
    Mix.raise("--claim-partitions must be a power of two from 2 through 64")
  end

  defp migration_path(repo, options) do
    options[:migrations_path] ||
      if options[:tenants] do
        repo.config()[:tenant_migrations_path] ||
          Path.join(source_repo_priv(repo), "tenant_migrations")
      else
        repo.config()[:migrations_path] || Path.join(source_repo_priv(repo), "migrations")
      end
  end

  defp source_repo_priv(repo) do
    config = repo.config()
    priv = config[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"
    app = Keyword.fetch!(config, :otp_app)
    Path.join(Mix.Project.deps_paths()[app] || File.cwd!(), priv)
  end

  defp refuse_existing!(path) do
    if Path.wildcard(Path.join(path, "*_install_ash_onetime.exs")) != [] do
      Mix.raise("an ash_onetime install migration already exists in #{path}")
    end
  end

  defp response_partitions(today) do
    first = Date.beginning_of_month(today)

    for offset <- 0..12 do
      from = shift_month(first, offset)
      to = shift_month(first, offset + 1)

      %{
        name: "ash_onetime_response_payloads_#{from.year}_#{pad(from.month)}",
        from: from,
        to: to
      }
    end
  end

  defp shift_month(date, offset) do
    month_index = date.year * 12 + date.month - 1 + offset
    Date.new!(div(month_index, 12), rem(month_index, 12) + 1, 1)
  end

  defp template_path(name) do
    :ash_onetime
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("templates/migrations/#{name}")
  end

  defp timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    Enum.map_join([year, month, day, hour, minute, second], &pad/1)
  end

  defp pad(integer), do: integer |> Integer.to_string() |> String.pad_leading(2, "0")
end
