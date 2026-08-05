if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshOnetime.Install do
    @moduledoc """
    Installs `ash_onetime` formatting and its deterministic migration.

        mix igniter.install ash_onetime --repo MyApp.Repo

    Plug and Oban remain opt-in through `--with-plug` and `--with-oban`.
    """

    use Igniter.Mix.Task

    alias Igniter.Project.{Deps, Formatter}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: GenerateMigrations

    @shortdoc "Installs ash_onetime into an Ecto project"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_onetime,
        required: [:repo],
        schema: [
          repo: :string,
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
