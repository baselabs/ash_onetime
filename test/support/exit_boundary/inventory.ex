defmodule AshOnetime.Test.ExitBoundary.Inventory do
  @moduledoc false

  # Every declaration in each release's own erts/emulator/beam/bif.tab, including
  # quoted operators. Source: https://github.com/erlang/otp/blob/OTP-<release>/erts/emulator/beam/bif.tab
  # SHA-256 of the primary sources:
  # 28.5: e1ccf7bdef1d78da981c19051694528de4959640a04408ea7531316db24b07e9
  # 29.1.2: 55c88258e90745e701d00702266c6422e35c31c6796ce2086ea00fa00f9d8816
  @releases ["28.5", "29.1.2"]

  for release <- @releases do
    @external_resource Path.join(__DIR__, "bif_inventory_#{release}.tsv")
  end

  @inventories Map.new(@releases, fn release ->
    rows =
      Path.join(__DIR__, "bif_inventory_#{release}.tsv")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.drop(1)
      |> Enum.map(fn line ->
        [module, function, arity, kind, source] = String.split(line, "\t")
        atom = &(&1 |> String.trim("'") |> String.to_atom())
        %{module: atom.(module), function: atom.(function), arity: String.to_integer(arity),
          kind: kind, source: source}
      end)
    {release, rows}
  end)

  @runtime Path.join([List.to_string(:code.root_dir()), "releases",
    List.to_string(:erlang.system_info(:otp_release)), "OTP_VERSION"])
    |> File.read!() |> String.trim()

  def releases, do: @releases

  def release do
    release = @runtime
    bif_rows(release)
    release
  end

  def bif_rows, do: bif_rows(release())

  def bif_rows(release) do
    case Map.fetch(@inventories, release) do
      {:ok, rows} -> rows
      :error -> raise ArgumentError, "no exit-boundary inventory for OTP #{release}"
    end
  end

  @doc "The running release's full version, from its OTP_VERSION file."
  def running_release do
    major = :erlang.system_info(:otp_release) |> List.to_string()
    [:code.root_dir() |> List.to_string(), "releases", major, "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end
end
