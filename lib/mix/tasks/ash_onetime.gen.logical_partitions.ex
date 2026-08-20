defmodule Mix.Tasks.AshOnetime.Gen.LogicalPartitions do
  @moduledoc """
  Generates the reversible logical-partition upgrade for an existing `ash_onetime` install.

      mix ash_onetime.gen.logical_partitions --repo MyApp.Repo

  Existing claims and payloads are backfilled into the `global` partition. The generated down
  migration refuses while any non-global row exists, so rollback cannot merge distinct locator
  authorities.
  """

  use Mix.Task

  import Mix.Generator, only: [create_directory: 1, create_file: 2]

  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

  @shortdoc "Generates the logical-partition upgrade migration"
  @switches [
    repo: :string,
    migrations_path: :string,
    timestamp: :string,
    tenants: :boolean
  ]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid ash_onetime gen.logical_partitions arguments")
    end

    repo = parse_repo!(options[:repo])
    path = migration_path(repo, options)
    create_directory(path)

    file =
      Path.join(
        path,
        "#{parse_timestamp!(options[:timestamp])}_add_ash_onetime_logical_partitions.exs"
      )

    create_file(file, GenerateMigrations.render_logical_partition_upgrade(repo, []))
    file
  end

  defp parse_repo!(nil), do: Mix.raise("--repo is required")

  defp parse_repo!(repo_name) do
    repo = Module.safe_concat(String.split(repo_name, ".", trim: true))

    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo
    else
      Mix.raise("repo #{repo_name} is not available")
    end
  rescue
    ArgumentError -> Mix.raise("repo #{repo_name} is not available")
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

  defp parse_timestamp!(nil), do: GenerateMigrations.timestamp()

  defp parse_timestamp!(value) when is_binary(value) do
    case Calendar.ISO.parse_naive_datetime(
           String.slice(value, 0, 4) <>
             "-" <>
             String.slice(value, 4, 2) <>
             "-" <>
             String.slice(value, 6, 2) <>
             "T" <>
             String.slice(value, 8, 2) <>
             ":" <>
             String.slice(value, 10, 2) <> ":" <> String.slice(value, 12, 2)
         ) do
      {:ok, _naive_datetime} when byte_size(value) == 14 -> value
      _other -> Mix.raise("--timestamp must be a valid UTC YYYYMMDDHHMMSS value")
    end
  rescue
    _exception -> Mix.raise("--timestamp must be a valid UTC YYYYMMDDHHMMSS value")
  end
end
