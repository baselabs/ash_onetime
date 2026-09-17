# Dependency currency gate.
#
# Policy: everything resolver-updatable gets updated now; anything not at
# latest must be a deliberate pin with an inline reason in mix.exs.
#
# Exit codes:
#   0 - no resolvable drift (blocked pins are printed, not fatal — their
#       reason lives inline in mix.exs by policy)
#   1 - `mix hex.outdated` shows "Update possible" rows (resolvable drift)
#   2 - `mix hex.outdated` itself failed or its table could not be parsed
#
# Status literals come from Mix.Tasks.Hex.Outdated (hex 2.5.1):
#   "Up-to-date" | "Update possible" | "Update not possible"
#
# Run: mix run --no-start scripts/check_deps_currency.exs — portable across
# macOS/Linux/Windows (spawning mix goes through AshOnetime.Portable).
Code.require_file("#{__DIR__}/portable.exs")

defmodule AshOnetime.DepCurrencyCheck do
  @moduledoc false

  # Keep the caller-cwd contract of the original shell gate: operate from the
  # repo root regardless of the caller's working directory.
  def main do
    File.cd!(Path.expand("..", __DIR__))

    # hex.outdated exits nonzero whenever anything is outdated, which is the
    # normal case this gate classifies itself — never treat that as failure.
    {outdated_output, _outdated_exit} =
      AshOnetime.Portable.cmd("mix", ["hex.outdated"], stderr_to_stdout: true)

    outdated_output = ansi_stripped(outdated_output)

    parsed =
      outdated_output
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.map(&parse_row/1)

    {up_to_date, drift, pinned} =
      Enum.reduce(parsed, {0, [], []}, fn
        :up_to_date, {utd, dr, p} -> {utd + 1, dr, p}
        {:drift, status_row}, {utd, dr, p} -> {utd, [status_row | dr], p}
        {:pinned, status_row}, {utd, dr, p} -> {utd, dr, [status_row | p]}
        :ignore, acc -> acc
      end)

    # Not a single status row recognized is the sole "table not parsed" signal.
    # An all-up-to-date table parses fine but yields no rows, so an empty
    # drift/pinned list is NOT a failure.
    if up_to_date + length(drift) + length(pinned) == 0 do
      IO.puts(
        :stderr,
        "check_deps_currency: no dependency table parsed — hex.outdated failed or changed format:"
      )

      IO.puts(:stderr, outdated_output)
      System.halt(2)
    end

    if pinned != [] do
      IO.puts(
        "Held below latest by the requirement chain — each needs an inline reason in mix.exs:"
      )

      Enum.each(pinned, fn status_row ->
        IO.puts("  #{status_row}")
        name = status_row |> String.split(" ") |> hd()

        {detail, _exit} =
          AshOnetime.Portable.cmd("mix", ["hex.outdated", name], stderr_to_stdout: true)

        detail
        |> ansi_stripped()
        |> String.split(["\r\n", "\n"])
        |> Enum.each(&IO.puts("    #{&1}"))
      end)
    end

    if drift != [] do
      IO.puts(
        :stderr,
        "Resolvable dependency drift — update now (mix deps.update <name>) or pin deliberately with an inline reason in mix.exs:"
      )

      Enum.each(drift, &IO.puts(:stderr, "  #{&1}"))
      System.halt(1)
    end

    IO.puts(
      "No resolvable dependency drift; every direct dep is at latest or deliberately pinned."
    )
  end

  # Same field layout the original shell gate parsed in awk (1-based fields on
  # the version columns anchor on the STATUS tokens, not the line edges:
  # hex.outdated prints `Package [env] Current Latest <status words>`, where
  # the env column (dev / dev,test) is optional — a LEFT anchor misprints
  # env-annotated rows (observed: "ex_doc dev -> 0.40.3") and a plain
  # right-edge anchor misprints when the requirement column carries spaces.
  # current/latest sit immediately before "Update possible" (2 tokens) or
  # "Update not possible" (3 tokens).
  defp parse_row(line) do
    fields = String.split(line)
    count = length(fields)
    last = if(count == 0, do: nil, else: Enum.at(fields, count - 1))

    cond do
      count >= 1 and last == "Up-to-date" ->
        :up_to_date

      count >= 5 and Enum.at(fields, count - 2) == "Update" and last == "possible" ->
        {:drift, version_row(fields, 2)}

      count >= 6 and Enum.at(fields, count - 3) == "Update" and
        Enum.at(fields, count - 2) == "not" and
          last == "possible" ->
        {:pinned, version_row(fields, 3)}

      true ->
        :ignore
    end
  end

  defp version_row(fields, status_width) do
    count = length(fields)

    "#{Enum.at(fields, 0)} #{Enum.at(fields, count - status_width - 2)} -> #{Enum.at(fields, count - status_width - 1)}"
  end

  defp ansi_stripped(text) do
    String.replace(text, ~r/\e\[[0-9;]*m/, "")
  end
end

AshOnetime.DepCurrencyCheck.main()
