defmodule AshOnetime.Test.ExitBoundary.PathFrameWitnesses do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.{Compiled, Completeness, PathFrames, Scenarios}

  # These are real guarded production raises. No captured stack, event, hook or
  # environment is synthesized. Both BEAM bytes and compiler options are restored
  # before the next path runs.
  def capture(context, values) do
    for stage <- [:reserve, :producer, :complete],
        type <- [:crud, :action],
        reduce: [] do
      pairs -> pairs ++ capture_stage(context, values, stage, type)
    end
  end

  defp capture_stage(context, values, stage, type) do
    {path, subject} = source_site(type)
    function = if stage == :producer, do: :produce, else: stage
    header = stage_header(stage, type, subject)
    source = File.read!(path)
    unless length(:binary.matches(source, header)) == 1, do: raise("U14 source site missing")

    guarded =
      header <>
        "    if #{subject}.resource == AshOnetime.Test.ExitBoundary.Withheld do\n" <>
        "      Process.info(self(), :current_stacktrace)\n" <>
        "      raise ArgumentError, \"U14 #{function} production raise\"\n" <>
        "    end\n"

    Compiled.with_source(String.replace(source, header, guarded, global: false), path, fn ->
      for row <- Scenarios.rows(),
          row.branch == :execute,
          row.type == :action == (type == :action),
          do: capture_path(row, values, context, stage, function)
    end)
  end

  defp source_site(:action), do: {"lib/ash_onetime/generic_action.ex", "input"}
  defp source_site(:crud), do: {"lib/ash_onetime/change.ex", "changeset"}

  defp stage_header(:reserve, _, subject),
    do: "  defp reserve(#{subject}, protection, context, delivery) do\n"

  defp stage_header(:producer, _, subject),
    do: "  defp produce(#{subject}, handle, protection, context) do\n"

  defp stage_header(:complete, :action, _), do: "  defp complete(input, result) do\n"
  defp stage_header(:complete, :crud, _), do: "  defp complete(changeset, callback) do\n"

  defp capture_path(row, values, context, stage, function) do
    row = Map.put(row, :frame_stage, stage)
    pair = Scenarios.observe(row, values, context)
    stacks = Completeness.stacks(pair.run.run.events)
    frames = PathFrames.build(row, pair.run.hooks)

    for frame <- frames do
      unless Enum.any?(stacks, &PathFrames.witness?(&1, frame)),
        do: raise("U14 missing #{inspect({PathFrames.path(row), frame.mfa})}")
    end

    raised? =
      Enum.any?(pair.run.run.events, fn
        %{event: {_, :exception_from, {_, ^function, _}, _}} -> true
        _ -> false
      end)

    unless raised?, do: raise("U14 production raise did not execute")

    IO.puts(
      "U14_PRODUCTION_RAISE: " <>
        inspect(%{path: PathFrames.path(row), stacks: Enum.uniq(stacks)},
          pretty: true,
          limit: :infinity
        )
    )

    Map.put(pair, :path_frame_declarations, frames)
  end
end
