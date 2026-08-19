defmodule Mix.Tasks.AshOnetime.Doctor do
  @moduledoc """
  Checks the install health of `ash_onetime`: the Ash security floor, Oban queue configuration,
  and prefix validity. Run after install and after each upgrade to catch the silent-failure modes
  that have no runtime signal.

      mix ash_onetime.doctor --repo MyApp.Repo
      mix ash_onetime.doctor --repo MyApp.Repo --prefix tenant_1

  **Checks:**

  - **Ash floor** (fatal): the running Ash version must be >= 3.31.1 (the CVE-floor pinned in
    `mix.exs` `ash_requirement/0`). A below-floor Ash is a security defect, not an advisory.
  - **Oban queues** (advisory when Oban loaded): the three maintenance workers require
    `:ash_onetime_cleanup`, `:ash_onetime_reap`, and `:ash_onetime_partitions`. A missing
    `:ash_onetime_partitions` queue silently strands the retention-safety path (forward partition
    creation never executes). The doctor scans the consumer's Oban config for the three queues and
    warns on any missing. This is advisory — a consumer may configure Oban dynamically at runtime.
  - **Prefix validity** (when `--prefix` given): the prefix must be 1..63 bytes (PostgreSQL's
    NAMEDATALEN bound).

  Exits non-zero only on a FAIL (Ash below floor, missing `--repo`, invalid `--prefix`).
  Advisory warnings return `:ok`.
  """

  use Mix.Task

  @shortdoc "Checks ash_onetime install health (Ash floor, Oban queues, prefix validity)"

  @switches [repo: :string, prefix: :string]

  # Mirrors mix.exs ash_requirement/0's floor (>= 3.31.1). The three CVEs that motivated this
  # floor are documented in mix.exs:62-66. Update both together.
  @ash_floor Version.parse!("3.31.1")

  # The three required Oban queues (authoritative source: the three `use Oban.Worker, queue:`
  # declarations in lib/ash_onetime/oban/{cleanup,reap,partition}_worker.ex).
  @required_oban_queues [:ash_onetime_cleanup, :ash_onetime_reap, :ash_onetime_partitions]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("compile")
    {options, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid ash_onetime doctor arguments")

    _repo = parse_repo!(options[:repo])
    prefix = parse_prefix!(options[:prefix])

    failures =
      [
        &check_ash_floor/0,
        &check_oban_queues/0,
        fn -> check_prefix(prefix) end
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
    case floor_status(running_ash_version()) do
      :ok ->
        Mix.shell().info("[OK]  Ash #{running_ash_version()} >= floor #{@ash_floor}.")
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
    oban_queue_status(Code.ensure_loaded?(Oban), collect_oban_queues())
    |> render_oban_status()
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
