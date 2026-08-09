defmodule Mix.Tasks.AshOnetime.Gen.RollForward do
  @moduledoc """
  Generates the SEC-5/SEC-6 forward migration for an existing `ash_onetime` install.

      mix ash_onetime.gen.roll_forward --repo MyApp.Repo
      mix ash_onetime.gen.roll_forward --repo MyApp.Repo --months 18 --partition-start 2026-01-01

  The generated migration adds the `response_partition` index, back-fills monthly
  `response_payloads` range partitions from the install `--partition-start` through `--months`,
  and drains past-retention claims whose payload is stranded in the `_default` partition. Run it
  with `mix ecto.migrate`. For greenfield installs the install migration already carries the
  index; this task is for installs that predate it or that have crossed the partition window.
  """

  use Mix.Task

  import Mix.Generator, only: [create_directory: 1, create_file: 2]

  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

  @shortdoc "Generates the ash_onetime SEC-5/SEC-6 forward migration"
  # NOTE: --prefix is intentionally NOT a switch (unlike the runtime roll task). The generated
  # migration resolves its prefix at RUN time via the Ecto migration's prefix()/0 callback, so a
  # generation-time --prefix would be a dead switch. Use --tenants to target tenant migrations.
  @switches [
    repo: :string,
    months: :integer,
    partition_start: :string,
    migrations_path: :string,
    timestamp: :string,
    tenants: :boolean
  ]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid ash_onetime gen.roll_forward arguments")

    repo = parse_repo!(options[:repo])
    months = parse_months!(options[:months])
    partition_start = parse_partition_start!(options[:partition_start])
    path = migration_path(repo, options)

    create_directory(path)

    source =
      GenerateMigrations.render_roll_forward(repo,
        partition_start: partition_start,
        months: months
      )

    file = Path.join(path, "#{GenerateMigrations.timestamp()}_roll_forward_ash_onetime.exs")
    create_file(file, source)
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

  defp parse_months!(nil), do: 13

  defp parse_months!(value) when is_integer(value) and value >= 1 and value <= 24, do: value

  defp parse_months!(_value), do: Mix.raise("--months must be from 1 through 24")

  defp parse_partition_start!(nil), do: Date.beginning_of_month(Date.utc_today())

  defp parse_partition_start!(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{day: 1} = date} -> date
      _error -> Mix.raise("--partition-start must be the first day of a month")
    end
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
end
