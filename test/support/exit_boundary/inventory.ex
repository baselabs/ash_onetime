defmodule AshOnetime.Test.ExitBoundary.Inventory do
  @moduledoc false

  # The 550 BIF declarations of `erts/emulator/beam/bif.tab` at OTP 29.1.2, one row per
  # declaration (module, function, arity, kind, source line), as the release derivation
  # extracted them. Operators keep Erlang's quoted-atom spelling in the file ('and').

  @release "29.1.2"
  @path Path.join(__DIR__, "bif_inventory.tsv")
  @external_resource @path

  @rows @path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.map(fn line ->
          [module, function, arity, kind, source] = String.split(line, "\t")
          unquote_atom = &(&1 |> String.trim("'") |> String.to_atom())

          %{
            module: unquote_atom.(module),
            function: unquote_atom.(function),
            arity: String.to_integer(arity),
            kind: kind,
            source: source
          }
        end)

  def release, do: @release
  def bif_rows, do: @rows

  @doc "The running release's full version, from its `OTP_VERSION` file."
  def running_release do
    major = :erlang.system_info(:otp_release) |> List.to_string()

    [:code.root_dir() |> List.to_string(), "releases", major, "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end
end
