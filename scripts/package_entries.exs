defmodule AshOnetime.PackageEntries do
  @moduledoc false

  # Path rules for files inside the published package archive, shared by
  # scripts/check_package.exs and the package boundary tests.
  @forbidden_prefixes ["_build/", "config/", "deps/", "scripts/", "test/"]

  @doc "The refusal message for a package entry path, or nil when the entry may ship."
  def refusal(entry) when is_binary(entry) do
    cond do
      Enum.any?(@forbidden_prefixes, &String.starts_with?(entry, &1)) ->
        "forbidden dev/test entry in package: #{entry}"

      Enum.any?(Path.split(entry), &String.starts_with?(&1, ".")) ->
        "forbidden hidden entry in package: #{entry}"

      true ->
        nil
    end
  end
end
