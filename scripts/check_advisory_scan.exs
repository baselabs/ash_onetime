# Proves an osv-scanner run covered the whole lock: the number of packages in its JSON report
# (`--all-packages --format json`) must equal the lock's `:hex` and `:git` entries, the two
# kinds the scanner reads from mix.lock. A smaller count means locked packages went unscanned;
# a lock with neither kind proves nothing and fails too.
#
#     mix run --no-start --no-compile --no-deps-check scripts/check_advisory_scan.exs LOCK REPORT
defmodule AshOnetime.AdvisoryScanCheck do
  @moduledoc false

  @scanned_kinds [:hex, :git]

  def main([lock, report]) do
    case check(lock, report) do
      {:ok, count} ->
        IO.puts("advisory scan covered all #{count} hex and git entries of #{lock}")

      {:error, message} ->
        IO.puts(:stderr, "advisory scan check failed: " <> message)
        System.halt(1)
    end
  end

  def main(_arguments) do
    IO.puts(:stderr, "usage: scripts/check_advisory_scan.exs LOCK REPORT")
    System.halt(2)
  end

  def check(lock, report) do
    with {:ok, locked} <- locked_count(lock),
         {:ok, scanned} <- scanned_count(report) do
      compare(locked, scanned)
    end
  end

  defp locked_count(path) do
    if File.regular?(path) do
      count =
        path
        |> Mix.Dep.Lock.read()
        |> Enum.count(fn {_name, entry} ->
          is_tuple(entry) and elem(entry, 0) in @scanned_kinds
        end)

      {:ok, count}
    else
      {:error, "lock file not found: #{path}"}
    end
  end

  defp scanned_count(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"results" => results}} when is_list(results) <- JSON.decode(body) do
      {:ok, results |> Enum.flat_map(&Map.get(&1, "packages", [])) |> length()}
    else
      _other -> {:error, "scanner report is missing or unreadable: #{path}"}
    end
  end

  defp compare(0, _scanned), do: {:error, "the lock holds no hex or git entries to scan"}
  defp compare(count, count), do: {:ok, count}

  defp compare(locked, scanned),
    do:
      {:error,
       "the scanner reported #{scanned} packages; the lock holds #{locked} hex and git entries"}
end

AshOnetime.AdvisoryScanCheck.main(System.argv())
