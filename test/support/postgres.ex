defmodule AshOnetime.Test.Postgres do
  @moduledoc false

  @github Path.expand("../../.github", __DIR__)

  def contract do
    case System.get_env("ASH_ONETIME_POSTGRES_COMPAT_MAJOR") do
      nil ->
        engine = File.read!(Path.join(@github, "postgres.ref"))
        [_, version, major] = Regex.run(~r/:(([0-9]+)\.[0-9]+)-inputs-/, engine)
        %{major: String.to_integer(major), version: version, data: "/var/lib/pg/data"}

      major ->
        lanes = @github |> Path.join("postgres-compat.json") |> File.read!() |> Jason.decode!()
        lane = Enum.find(lanes, &(&1["major"] == major))
        unless lane, do: raise("PostgreSQL compatibility major is not declared")
        [_, version] = Regex.run(~r/\Apostgres:([0-9]+\.[0-9]+)@sha256:/, lane["image"])

        %{
          major: String.to_integer(lane["major"]),
          version: version,
          data: "/var/lib/postgresql/data"
        }
    end
  end
end
