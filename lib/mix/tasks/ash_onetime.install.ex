if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshOnetime.Install do
    @moduledoc """
    Installs `ash_onetime` formatting and its deterministic migration.

        mix igniter.install ash_onetime --repo MyApp.Repo

    Plug and Oban remain opt-in through `--with-plug` and `--with-oban`. Pass
    `--resource MyApp.MyResource` (repeatable) to wire `AshOnetime.Resource` into a resource
    and scaffold a starter `onetime` block there; per-resource opt-in stays the default.
    """

    use Igniter.Mix.Task

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Deps, Formatter}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

    @shortdoc "Installs ash_onetime into an Ecto project"

    # A scaffolded, commented `onetime` block. An empty `onetime do end` compiles to "no
    # protected actions", so the starter never protects an action the consumer did not name.
    @starter_onetime_block ~s"""
    onetime do
      # protect :your_action do
      #   strategy :idempotency | :one_time_nonce
      # end
      #
      # See documentation/getting-started.md for the full protect-block shape.
    end
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_onetime,
        required: [:repo],
        schema: [
          repo: :string,
          resource: :keep,
          claims: :string,
          claim_partitions: :integer,
          partition_start: :string,
          timestamp: :string,
          with_plug: :boolean,
          with_oban: :boolean
        ],
        aliases: [r: :repo]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      repo = Igniter.Project.Module.parse(options[:repo])

      with {:ok, hash_partitions} <- claim_partitions(options),
           {:ok, partition_start} <- partition_start(options[:partition_start]),
           {:ok, timestamp} <- migration_timestamp(options[:timestamp]) do
        source =
          GenerateMigrations.render(repo,
            hash_partitions: hash_partitions,
            partition_start: partition_start
          )

        path =
          Path.join(
            "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}/migrations",
            "#{timestamp}_install_ash_onetime.exs"
          )

        igniter
        |> Formatter.import_dep(:ash_onetime)
        |> add_optional_dependency(options[:with_plug], {:plug, "~> 1.20"})
        |> add_optional_dependency(options[:with_oban], {:oban, "~> 2.23"})
        |> Igniter.create_new_file(path, source)
        |> wire_resources(List.wrap(options[:resource]))
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp claim_partitions(options) do
      case {options[:claims], options[:claim_partitions]} do
        {nil, nil} ->
          {:ok, nil}

        {"plain", nil} ->
          {:ok, nil}

        {"hash", nil} ->
          {:error, "--claims hash requires --claim-partitions"}

        {"hash", count} ->
          hash_partitions(count)

        {nil, _count} ->
          {:error, "--claim-partitions requires --claims hash"}

        {_other, _count} ->
          {:error, "--claims must be hash when provided"}
      end
    end

    defp hash_partitions(count)
         when is_integer(count) and count >= 2 and count <= 64 and
                Bitwise.band(count, count - 1) == 0,
         do: {:ok, count}

    defp hash_partitions(_count),
      do: {:error, "--claim-partitions must be a power of two from 2 through 64"}

    defp partition_start(nil), do: {:ok, Date.beginning_of_month(Date.utc_today())}

    defp partition_start(value) do
      case Date.from_iso8601(value) do
        {:ok, %Date{day: 1} = date} -> {:ok, date}
        _error -> {:error, "--partition-start must be the first day of a month"}
      end
    end

    defp migration_timestamp(nil), do: {:ok, GenerateMigrations.timestamp()}

    defp migration_timestamp(value) do
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
        {:ok, value}
      else
        _invalid -> {:error, "--timestamp must be a valid UTC YYYYMMDDHHMMSS value"}
      end
    end

    defp add_optional_dependency(igniter, true, dependency),
      do: Deps.add_dep(igniter, dependency)

    defp add_optional_dependency(igniter, _false, _dependency), do: igniter

    # `--resource` is opt-in and repeatable. Each named resource gets the extension injected
    # into its `use Ash.Resource` call and a starter `onetime` block scaffolded when absent.
    # Per-resource opt-in stays the default, so the block ships empty (an empty `onetime do
    # end` compiles to "no protected actions"); the protect-block shape is documented in the
    # getting-started guide rather than auto-generated, so the installer never protects an
    # action the consumer did not name.
    defp wire_resources(igniter, []), do: igniter

    defp wire_resources(igniter, [name | rest]) do
      resource = Igniter.Project.Module.parse(name)

      igniter
      |> wire_resource(resource)
      |> wire_resources(rest)
    end

    defp wire_resource(igniter, resource) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, resource)

      if exists? do
        # `resource?/2` may initialize the module index on the igniter it returns, so thread
        # that igniter forward and fail loud if the target is not an Ash.Resource rather than
        # silently injecting a non-compiling `onetime` block into it.
        {is_resource?, igniter} = resource?(igniter, resource)

        if is_resource? do
          igniter
          |> Spark.Igniter.add_extension(resource, Ash.Resource, :extensions, AshOnetime.Resource)
          |> scaffold_onetime_block(resource)
        else
          Igniter.add_issue(
            igniter,
            "--resource #{inspect(resource)} is not an Ash.Resource"
          )
        end
      else
        Igniter.add_issue(
          igniter,
          "--resource #{inspect(resource)} does not match a module in this project"
        )
      end
    end

    # A target qualifies for wiring only if it declares `use Ash.Resource`. This mirrors the
    # `move_to_use` precondition that `Spark.Igniter.add_extension/5` silently no-ops without,
    # so a non-resource (e.g. an Ash.Domain) is rejected explicitly instead of receiving a
    # stray `onetime` block it cannot compile. Returns `{boolean, igniter}` because
    # `find_module/2` may mutate the igniter (module index) and its contract forbids discarding
    # it. Read-only on the source: `find_module` returns the zipper without staging an edit.
    defp resource?(igniter, resource) do
      case Igniter.Project.Module.find_module(igniter, resource) do
        {:ok, {igniter, _source, zipper}} ->
          is_resource? =
            with {:ok, zipper} <- Common.move_to_do_block(zipper),
                 {:ok, _} <- Igniter.Code.Module.move_to_use(zipper, Ash.Resource) do
              true
            else
              _ -> false
            end

          {is_resource?, igniter}

        {:error, igniter} ->
          {false, igniter}
      end
    end

    defp scaffold_onetime_block(igniter, resource) do
      Igniter.Project.Module.find_and_update_module!(igniter, resource, fn zipper ->
        case Function.move_to_function_call_in_current_scope(zipper, :onetime, 1) do
          # An `onetime do ... end` block already exists; leave it untouched.
          {:ok, _zipper} -> {:ok, zipper}
          :error -> {:ok, Common.add_code(zipper, @starter_onetime_block)}
        end
      end)
    end
  end
else
  defmodule Mix.Tasks.AshOnetime.Install do
    @moduledoc "Install task fallback when the optional Igniter dependency is absent."

    use Mix.Task

    @shortdoc "Installs ash_onetime into an Ecto project"

    @impl Mix.Task
    def run(_arguments) do
      Mix.raise("ash_onetime.install requires the optional :igniter dependency")
    end
  end
end
