defmodule Mix.Tasks.AshOnetime.Gen.Migrations do
  @moduledoc """
  Generates the PostgreSQL objects required by `ash_onetime`.

      mix ash_onetime.gen.migrations --repo MyApp.Repo
      mix ash_onetime.gen.migrations --repo MyApp.Repo --operation-hold
      mix ash_onetime.gen.migrations --repo MyApp.Repo --claims hash --claim-partitions 8
      mix ash_onetime.gen.migrations --repo MyApp.Repo --fact-tables ledger_facts,payment_facts

  `--operation-hold` generates the reversible upgrade for an existing installation,
  detecting plain or hash-partitioned claims and building indexes concurrently. It cannot
  be combined with install-only options. Apply it before running hold-aware callers.

  `--fact-tables` additionally generates the append-only fact tables backing
  `context_boundary` declarations (one migration creating every named table).
  Use `--tenants` to write to the repo tenant migration directory.
  """

  use Mix.Task

  import Mix.Generator, only: [create_directory: 1, create_file: 2]

  alias AshOnetime.Resource.ContextBoundary

  @shortdoc "Generates ash_onetime PostgreSQL migrations"
  @collision_constraint "UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)"
  @cleanup_comparator ">"
  @cleanup_delete_predicate "claims.logical_partition = candidates.logical_partition AND claims.operation_hash = candidates.operation_hash AND claims.id = candidates.id"
  @switches [
    repo: :string,
    operation_hold: :boolean,
    claims: :string,
    claim_partitions: :integer,
    fact_tables: :string,
    tenants: :boolean,
    migrations_path: :string,
    partition_start: :string,
    timestamp: :string
  ]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid ash_onetime migration generator arguments")
    end

    repo = parse_repo!(options[:repo])

    if options[:operation_hold],
      do: generate_operation_hold(repo, options),
      else: generate_install(repo, options)
  end

  defp generate_operation_hold(repo, options) do
    if Enum.any?(
         [:claims, :claim_partitions, :fact_tables, :partition_start],
         &Keyword.has_key?(options, &1)
       ),
       do: Mix.raise("--operation-hold cannot be combined with install options")

    path = migration_path(repo, options)
    create_directory(path)

    if Path.wildcard(Path.join(path, "*_add_ash_onetime_operation_hold.exs")) != [],
      do: Mix.raise("an operation-hold upgrade migration already exists")

    file =
      Path.join(
        path,
        "#{parse_timestamp!(options[:timestamp])}_add_ash_onetime_operation_hold.exs"
      )

    create_file(file, render_operation_hold_upgrade(repo, []))
    file
  end

  defp generate_install(repo, options) do
    hash_partitions = parse_claim_partitioning!(options)
    fact_tables = parse_fact_tables!(options[:fact_tables])
    path = migration_path(repo, options)
    create_directory(path)
    refuse_existing!(path)

    timestamp = parse_timestamp!(options[:timestamp])
    partition_start = parse_partition_start!(options[:partition_start])
    source = render(repo, hash_partitions: hash_partitions, partition_start: partition_start)
    file = Path.join(path, "#{timestamp}_install_ash_onetime.exs")
    create_file(file, source)
    Mix.shell().info("Generated #{file}")

    facts_file =
      if fact_tables != [] do
        facts_source = render_fact_tables(repo, fact_tables: fact_tables)
        facts = Path.join(path, "#{timestamp}_ash_onetime_context_boundary_facts.exs")
        create_file(facts, facts_source)
        Mix.shell().info("Generated #{facts}")
        facts
      end

    facts_file || file
  end

  @doc "Renders the install migration deterministically for explicit options."
  @spec render(module(), keyword()) :: binary()
  def render(repo, options) when is_atom(repo) and is_list(options) do
    hash_partitions = render_partitioning!(Keyword.get(options, :hash_partitions))
    partition_start = render_partition_start!(Keyword.get(options, :partition_start))
    module = Module.concat([repo, Migrations, InstallAshOnetime])
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
        response_partitions: response_partitions(partition_start)
      )

    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  @doc """
  Renders the context-boundary fact-table migration deterministically for explicit
  options. Every table name is validated by
  `AshOnetime.Resource.ContextBoundary.validate_fact_table/1`; the migration creates
  each table (identity `seq`, GIN-indexed `tags`, tenant scoping, append-only trigger)
  and is reversible. Pure (no filesystem writes).
  """
  @spec render_fact_tables(module(), keyword()) :: binary()
  def render_fact_tables(repo, options) when is_atom(repo) and is_list(options) do
    fact_tables = render_fact_table_names!(Keyword.get(options, :fact_tables))
    module = Module.concat([repo, Migrations, AddAshOnetimeBoundaryFacts])

    source =
      "fact_tables.exs"
      |> template_path()
      |> EEx.eval_file(module: module, fact_tables: fact_tables)

    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  @doc """
  Renders the SEC-5/SEC-6 forward migration deterministically for existing installs: the
  response_partition index, a back-fill of monthly partitions from `partition_start` through
  `partition_start + months`, and the past-retention DEFAULT drain. Pure (no filesystem writes).
  """
  @spec render_roll_forward(module(), keyword()) :: binary()
  def render_roll_forward(repo, options) when is_atom(repo) and is_list(options) do
    partition_start = render_partition_start!(Keyword.get(options, :partition_start))
    months = render_months!(Keyword.get(options, :months))
    module = Module.concat([repo, Migrations, RollForwardAshOnetime])

    partitions =
      for offset <- 0..(months - 1) do
        from = shift_month(partition_start, offset)
        to = shift_month(partition_start, offset + 1)

        %{
          name: "ash_onetime_response_payloads_#{from.year}_#{pad(from.month)}",
          from: from,
          to: to
        }
      end

    source =
      "roll_forward.exs"
      |> template_path()
      |> EEx.eval_file(module: module, partitions: partitions)

    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  @doc "Renders the reversible logical-partition upgrade for an existing installation."
  @spec render_logical_partition_upgrade(module(), keyword()) :: binary()
  def render_logical_partition_upgrade(repo, options)
      when is_atom(repo) and is_list(options) do
    if options != [], do: raise(ArgumentError, "logical partition upgrade accepts no options")

    module = Module.concat([repo, Migrations, AddAshOnetimeLogicalPartitions])

    source =
      "logical_partitions.exs"
      |> template_path()
      |> EEx.eval_file(module: module)

    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  @doc """
  Renders the reversible operation-hold upgrade for an existing plain or hash-partitioned
  installation. Adds and validates the hold constraint, concurrently builds cleanup and
  release indexes (attaching child indexes for hash claims), recovers invalid builds, and
  replaces the delete guard and cleanup function. Accepts no rendering options.
  """
  @spec render_operation_hold_upgrade(module(), keyword()) :: binary()
  def render_operation_hold_upgrade(repo, options) when is_atom(repo) and is_list(options) do
    if options != [], do: raise(ArgumentError, "operation hold upgrade accepts no options")

    "operation_hold.exs"
    |> template_path()
    |> EEx.eval_file(module: Module.concat([repo, Migrations, AddAshOnetimeOperationHold]))
    |> Code.format_string!()
    |> IO.iodata_to_binary()
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

  defp parse_fact_tables!(nil), do: []

  defp parse_fact_tables!(names) when is_binary(names) do
    case names |> String.split(",", trim: true) |> Enum.map(&validate_fact_table!/1) do
      [] -> Mix.raise("--fact-tables requires at least one table name")
      tables -> Enum.uniq(tables)
    end
  end

  defp validate_fact_table!(name) do
    case ContextBoundary.validate_fact_table(name) do
      {:ok, validated} -> validated
      {:error, message} -> Mix.raise("fact table name #{inspect(name)} is invalid: #{message}")
    end
  end

  defp render_fact_table_names!(nil), do: raise(ArgumentError, "fact_tables option is required")

  defp render_fact_table_names!(names) when is_list(names) and names != [] do
    Enum.map(names, &validate_fact_table!/1)
  end

  defp render_fact_table_names!(_names),
    do: raise(ArgumentError, "fact_tables must be a nonempty list of table names")

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

  defp parse_partition_start!(nil), do: Date.beginning_of_month(Date.utc_today())

  defp parse_partition_start!(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{day: 1} = date} -> date
      _error -> Mix.raise("--partition-start must be the first day of a month")
    end
  end

  defp render_partition_start!(nil), do: Date.beginning_of_month(Date.utc_today())
  defp render_partition_start!(%Date{day: 1} = date), do: date
  defp render_partition_start!(_date), do: raise(ArgumentError, "invalid partition start")

  defp render_months!(nil), do: 13
  defp render_months!(months) when is_integer(months) and months >= 1 and months <= 24, do: months
  defp render_months!(_months), do: raise(ArgumentError, "invalid months")

  defp render_partitioning!(nil), do: nil
  defp render_partitioning!(count), do: validate_partition_count!(count)

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

  defp parse_timestamp!(nil), do: timestamp()

  defp parse_timestamp!(value) when is_binary(value) do
    with [_, year, month, day, hour, minute, second] <-
           Regex.run(~r/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/, value),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         {:ok, _date} <- Date.new(year, month, day),
         {:ok, _time} <- Time.new(hour, minute, second) do
      value
    else
      _invalid -> Mix.raise("--timestamp must be a valid UTC YYYYMMDDHHMMSS value")
    end
  end

  @doc false
  def timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    Enum.map_join([year, month, day, hour, minute, second], &pad/1)
  end

  defp pad(integer), do: integer |> Integer.to_string() |> String.pad_leading(2, "0")
end
