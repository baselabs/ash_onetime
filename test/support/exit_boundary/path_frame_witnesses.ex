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
      pairs ->
        {path, subject} =
          if type == :action,
            do: {"lib/ash_onetime/generic_action.ex", "input"},
            else: {"lib/ash_onetime/change.ex", "changeset"}

        function = if stage == :producer, do: :produce, else: stage

        header =
          case stage do
            :reserve -> "  defp reserve(#{subject}, protection, context, delivery) do\n"
            :producer -> "  defp produce(#{subject}, handle, protection, context) do\n"
            :complete when type == :action -> "  defp complete(input, result) do\n"
            :complete -> "  defp complete(changeset, callback) do\n"
          end

        source = File.read!(path)
        unless length(:binary.matches(source, header)) == 1, do: raise("U14 source site missing")

        guarded =
          header <>
            "    if #{subject}.resource == AshOnetime.Test.ExitBoundary.Withheld do\n" <>
            "      Process.info(self(), :current_stacktrace)\n" <>
            "      raise ArgumentError, \"U14 #{function} production raise\"\n" <>
            "    end\n"

        captured =
          Compiled.with_source(String.replace(source, header, guarded, global: false), path, fn ->
            for row <- Scenarios.rows(),
                row.branch == :execute,
                (row.type == :action) == (type == :action) do
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

              IO.inspect(%{path: PathFrames.path(row), stacks: Enum.uniq(stacks)},
                label: "U14_PRODUCTION_RAISE",
                limit: :infinity
              )

              Map.put(pair, :path_frame_declarations, frames)
            end
          end)

        pairs ++ captured
    end
  end
end
