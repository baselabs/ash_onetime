defmodule Mix.Tasks.AshOnetime.Doctor do
  @moduledoc """
  Checks the install health of `ash_onetime`: the Ash security floor, Oban queue configuration,
  and prefix validity. Run after install and after each upgrade to catch the silent-failure modes
  that have no runtime signal.

      mix ash_onetime.doctor --repo MyApp.Repo
      mix ash_onetime.doctor --repo MyApp.Repo --prefix tenant_1

  **Checks:**

  - **Ash floor** (fatal): the running Ash version must be >= 3.31.3 (the CVE-floor pinned in
    `mix.exs` `ash_requirement/0`). A below-floor Ash is a security defect, not an advisory.
  - **Oban queues** (advisory when Oban loaded): the three maintenance workers require
    `:ash_onetime_cleanup`, `:ash_onetime_reap`, and `:ash_onetime_partitions`. A missing
    `:ash_onetime_partitions` queue silently strands the retention-safety path (forward partition
    creation never executes). The doctor scans the consumer's Oban config for the three queues and
    warns on any missing. This is advisory — a consumer may configure Oban dynamically at runtime.
  - **Prefix validity** (when `--prefix` given): the prefix must be 1..63 bytes (PostgreSQL's
    NAMEDATALEN bound).
  - **Schema currency** (fatal, only with `--live`): queries the database (read-only, catalog
    tables) and fails when the installed schema is not current for this package version — the
    failure mode of upgrading the package without running its migrations. Checks: the
    `logical_partition` column on both claim tables (the 1.1 logical-partition upgrade), the
    `ash_onetime_response_payloads` partitioned table and its `_default` partition, the three
    cleanup/reap functions (by name and arity), and the two delete-guard triggers.

      mix ash_onetime.doctor --repo MyApp.Repo --live
      mix ash_onetime.doctor --repo MyApp.Repo --live --prefix tenant_1

    Without `--live` the doctor stays offline (compile-env checks only). The schema checked is
    `--prefix` when given, else `public`.

  Exits non-zero only on a FAIL (Ash below floor, missing `--repo`, invalid `--prefix`, or — with
  `--live` — a missing/stale schema). Advisory warnings return `:ok`.
  """

  use Mix.Task

  alias Ecto.Adapters.SQL

  @shortdoc "Checks ash_onetime install health (Ash floor, Oban queues, prefix validity)"

  @switches [repo: :string, prefix: :string, live: :boolean]

  # Mirrors mix.exs ash_requirement/0's floor (>= 3.31.3). The CVEs that motivated this floor
  # are documented alongside that requirement: EEF-CVE-2026-55736/-70395/-69659 (fixed at or
  # below 3.31.1) and EEF-CVE-2026-67579 (HIGH, fixed in 3.31.3 — the binding constraint).
  # Update both together.
  @ash_floor Version.parse!("3.31.3")

  # The three required Oban queues (authoritative source: the three `use Oban.Worker, queue:`
  # declarations in lib/ash_onetime/oban/{cleanup,reap,partition}_worker.ex).
  @required_oban_queues [:ash_onetime_cleanup, :ash_onetime_reap, :ash_onetime_partitions]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid ash_onetime doctor arguments")

    repo = parse_repo!(options[:repo])
    prefix = parse_prefix!(options[:prefix])

    failures =
      [
        &check_ash_floor/0,
        &check_oban_queues/0,
        fn -> check_prefix(prefix) end,
        fn -> if options[:live], do: check_schema(repo, prefix), else: :ok end
      ]
      |> Enum.map(& &1.())
      |> Enum.filter(&(&1 == :fail))

    if failures == [] do
      Mix.shell().info("\nash_onetime doctor: all checks passed.")
      :ok
    else
      Mix.raise("ash_onetime doctor: #{length(failures)} check(s) failed")
    end
  end

  # Pure verdicts for the Ash floor and the Oban queue advisory, extracted so the reject
  # path and the not-loaded arm are directly testable — the running application's Ash
  # version and Oban load state cannot be varied inside the test environment. The
  # private check functions below only render these results.
  @doc false
  def floor_status(nil),
    do: {:fail, "Ash is not loaded — ash_onetime requires Ash >= #{@ash_floor}."}

  @doc false
  def floor_status(version) do
    if Version.compare(version, @ash_floor) == :lt do
      {:fail,
       "Ash #{version} is below the security floor #{@ash_floor}. " <>
         "Upgrade Ash to >= #{@ash_floor} (CVE-justified, see mix.exs ash_requirement/0)."}
    else
      :ok
    end
  end

  @doc false
  def oban_queue_status(false, _configured_queues), do: {:ok, :oban_not_loaded}

  @doc false
  def oban_queue_status(true, configured_queues) do
    missing = Enum.reject(@required_oban_queues, &MapSet.member?(configured_queues, &1))

    cond do
      Enum.empty?(configured_queues) -> {:ok, :no_queue_config}
      missing == [] -> {:ok, :all_configured}
      true -> {:warn, {:missing, missing}}
    end
  end

  defp check_ash_floor do
    version = running_ash_version()

    case floor_status(version) do
      :ok ->
        Mix.shell().info("[OK]  Ash #{version} >= floor #{@ash_floor}.")
        :ok

      {:fail, message} ->
        Mix.shell().error("[FAIL] #{message}")
        :fail
    end
  end

  defp running_ash_version do
    case Application.spec(:ash, :vsn) do
      nil -> nil
      vsn -> Version.parse!(to_string(vsn))
    end
  end

  defp check_oban_queues do
    # Short-circuit the queue scan when Oban is absent — collect_oban_queues/0 is wasted
    # work without an Oban config to find.
    status =
      if Code.ensure_loaded?(Oban),
        do: oban_queue_status(true, collect_oban_queues()),
        else: oban_queue_status(false, MapSet.new())

    render_oban_status(status)
  end

  defp render_oban_status({:ok, :oban_not_loaded}) do
    Mix.shell().info(
      "[OK]  Oban not loaded — optional workers compile out; no queue check needed."
    )

    :ok
  end

  defp render_oban_status({:ok, :no_queue_config}) do
    Mix.shell().info(
      "[WARN] Oban is loaded but no queues found in Application config. " <>
        "If you configure Oban programmatically, verify these three queues exist: " <>
        "#{inspect(@required_oban_queues)}. " <>
        "See documentation/operations.md#upgrade-check for the stuck-available SQL."
    )

    :ok
  end

  defp render_oban_status({:ok, :all_configured}) do
    Mix.shell().info(
      "[OK]  All three required Oban queues configured: #{inspect(@required_oban_queues)}."
    )

    :ok
  end

  defp render_oban_status({:warn, {:missing, missing}}) do
    for queue <- missing do
      Mix.shell().info(
        "[WARN] Oban queue #{inspect(queue)} is not in the Application config. " <>
          "Add it to your Oban `queues:` config or the corresponding worker's jobs will sit unscheduled."
      )
    end

    Mix.shell().info(
      "      See documentation/operations.md#upgrade-check for the stuck-available SQL " <>
        "to detect an unconfigured queue."
    )

    :ok
  end

  defp collect_oban_queues do
    # Best-effort scan of Application env for Oban config with a `queues:` keyword. Oban config
    # is typically `config :my_app, Oban, queues: [...]` or `config :oban, Oban, queues: [...]`.
    # A consumer may configure dynamically (Programmatic config), in which case this scan finds
    # nothing and the advisory covers that case.
    for app <- [:oban | Enum.map(Application.loaded_applications(), &elem(&1, 0))],
        reduce: MapSet.new() do
      acc ->
        MapSet.union(acc, configured_queue_keys(Application.get_env(app, Oban)))
    end
  end

  defp configured_queue_keys(opts) when is_list(opts) do
    case Keyword.get(opts, :queues) do
      queues when is_list(queues) -> MapSet.new(Keyword.keys(queues))
      _other -> MapSet.new()
    end
  end

  defp configured_queue_keys(_other), do: MapSet.new()

  defp check_prefix(nil), do: :ok

  defp check_prefix(prefix) when is_binary(prefix) do
    if byte_size(prefix) in 1..63 do
      Mix.shell().info("[OK]  Prefix #{inspect(prefix)} is 1..63 bytes (NAMEDATALEN bound).")
      :ok
    else
      Mix.shell().error(
        "[FAIL] Prefix #{inspect(prefix)} is #{byte_size(prefix)} bytes; must be 1..63."
      )

      :fail
    end
  end

  # -- helpers mirrored from the runtime task family (reap.ex:59-78) --

  # -- live schema-currency check (--live) --
  #
  # All catalog reads target pg_catalog (pg_class/pg_attribute/pg_trigger/pg_proc), never
  # information_schema: system catalogs are not privilege-filtered, so a least-privilege
  # SELECT-only connection role still gets true verdicts instead of empty result sets.

  # Every table carrying the logical-partition authority component: both claim tables AND
  # the response-payloads table (the 1.1 upgrade adds the column to all three — checking
  # only the claim tables would pass a schema whose payload writes then fail).
  @authority_tables [
    "ash_onetime_idempotency_claims",
    "ash_onetime_nonce_claims",
    "ash_onetime_response_payloads"
  ]
  @expected_functions [
    {"ash_onetime_cleanup_idempotency", 1},
    {"ash_onetime_cleanup_nonce", 1},
    {"ash_onetime_reap_idempotency", 2}
  ]
  @expected_triggers ["ash_onetime_idempotency_delete_guard", "ash_onetime_nonce_delete_guard"]

  @claim_tables ["ash_onetime_idempotency_claims", "ash_onetime_nonce_claims"]

  @logical_partition_sql """
  SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'logical_partition'
  WHERE n.nspname = $1 AND c.relname = ANY($2)
  """
  @payload_table_sql """
  SELECT 1
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND c.relname = 'ash_onetime_response_payloads'
    AND c.relkind = 'p'
  """
  # The relpartbound = 'DEFAULT' predicate is load-bearing: a RANGE partition coincidentally
  # named ..._default must not satisfy the default-partition verdict.
  @default_partition_sql """
  SELECT 1
  FROM pg_inherits inheritance
  JOIN pg_class parent ON parent.oid = inheritance.inhparent
  JOIN pg_namespace parent_namespace ON parent_namespace.oid = parent.relnamespace
  JOIN pg_class child ON child.oid = inheritance.inhrelid
  WHERE parent_namespace.nspname = $1
    AND parent.relname = 'ash_onetime_response_payloads'
    AND child.relname = 'ash_onetime_response_payloads_default'
    AND pg_get_expr(child.relpartbound, child.oid) = 'DEFAULT'
  """
  @function_sql """
  SELECT p.proname, p.pronargs
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = $1 AND p.proname = ANY($2)
  """
  # Constrained to the claim tables by tgrelid — an identically named trigger on an
  # unrelated table must not satisfy the verdict — and DISTINCT because PostgreSQL clones
  # parent triggers onto every hash/range partition under the same name (a hash-partitioned
  # install reports the parent trigger plus one row per clone).
  @trigger_sql """
  SELECT DISTINCT t.tgname
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND NOT t.tgisinternal
    AND c.relname = ANY($2)
  """

  defp check_schema(repo, prefix) do
    schema = prefix || "public"

    with :ok <- ensure_repo_started(repo),
         {:ok, facts} <- live_schema_facts(repo, schema) do
      render_schema_verdicts(schema_status(facts), schema)
    else
      {:error, reason} -> live_query_failure(repo, reason)
    end
  end

  # The pure verdict seam, mirroring floor_status/oban_queue_status: the catalog facts are
  # gathered by live_schema_facts/2 against the database; THIS function decides pass/fail
  # from them, so every stale-schema shape is directly testable without a live connection.
  # A missing item is FAIL, never WARN: a schema that is not current for the running
  # package is the exact silent 3am failure mode (--store_invariant at first admission)
  # this check exists to catch at upgrade time.
  @doc false
  @spec schema_status(map()) :: [{:ok | :fail, String.t()}]
  def schema_status(facts) do
    [
      {length(facts.logical_partition_tables) == length(@authority_tables),
       "logical_partition column present on all three authority tables " <>
         "(found on: #{inspect(Enum.sort(facts.logical_partition_tables))})"},
      {facts.payload_table, "ash_onetime_response_payloads table present"},
      {facts.default_partition, "ash_onetime_response_payloads_default partition present"},
      {MapSet.new(facts.functions) == MapSet.new(@expected_functions),
       "cleanup/reap functions present with exact arities"},
      {Enum.sort(Enum.uniq(facts.triggers)) == Enum.sort(@expected_triggers),
       "delete-guard triggers present (found: #{inspect(Enum.sort(Enum.uniq(facts.triggers)))})"}
    ]
    |> Enum.map(fn {passed?, message} ->
      if passed?, do: {:ok, message}, else: {:fail, message}
    end)
  end

  defp live_schema_facts(repo, schema) do
    with {:ok, columns} <- query(repo, @logical_partition_sql, [schema, @authority_tables]),
         {:ok, payload} <- query(repo, @payload_table_sql, [schema]),
         {:ok, default} <- query(repo, @default_partition_sql, [schema]),
         {:ok, functions} <-
           query(repo, @function_sql, [schema, Enum.map(@expected_functions, &elem(&1, 0))]),
         {:ok, triggers} <- query(repo, @trigger_sql, [schema, @claim_tables]) do
      {:ok,
       %{
         logical_partition_tables: Enum.map(columns.rows, &hd/1),
         payload_table: payload.num_rows == 1,
         default_partition: default.num_rows == 1,
         functions: Enum.map(functions.rows, &List.to_tuple/1),
         triggers: Enum.map(triggers.rows, &hd/1)
       }}
    end
  end

  defp query(repo, sql, params) do
    case SQL.query(repo, sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp ensure_repo_started(repo) do
    # A cold `mix ash_onetime.doctor --live` VM has no applications started: a bare
    # repo.start_link/1 then dies through its linked DBConnection processes with an EXIT
    # that reaches the task (crash, not verdict). Load the app config, ensure the DB stack,
    # and catch exits so every failure becomes a verdict line instead of a crash.
    Mix.Task.run("app.config")

    _ = Enum.map([:db_connection, :postgrex, :ecto_sql], &Application.ensure_all_started/1)

    try do
      case repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, _reason} -> {:error, "repo failed to start (see application logs)"}
      end
    catch
      :exit, _reason -> {:error, "repo failed to start (see application logs)"}
    end
  end

  defp render_schema_verdicts(verdicts, schema) do
    Mix.shell().info("\nSchema currency (schema #{inspect(schema)}):")

    Enum.each(verdicts, fn
      {:ok, message} -> Mix.shell().info("[OK]  #{message}")
      {:fail, message} -> Mix.shell().error("[FAIL] #{message}")
    end)

    if Enum.any?(verdicts, &match?({:fail, _}, &1)) do
      Mix.shell().error(
        "      The schema is not current for this package version — run the outstanding " <>
          "ash_onetime migrations (see documentation/upgrading.md)."
      )

      :fail
    else
      :ok
    end
  end

  defp live_query_failure(repo, reason) do
    Mix.shell().error("[FAIL] live schema check could not query #{inspect(repo)}: #{reason}")

    :fail
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
