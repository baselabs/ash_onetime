defmodule AshOnetime.FormatterProbeTest do
  use ExUnit.Case, async: false

  @tag :format_probe
  test "compare native and configured formatting of multiline keyword constructs" do
    {configured, options} =
      Mix.Tasks.Format.formatter_for_file("test/support/exit_boundary/comparator.ex")

    native = fn text -> IO.iodata_to_binary([Code.format_string!(text, options), ?\n]) end

    inputs = [
      keyword_head: ~S"""
      defmodule FormatProbe do
        defp response_slot(%{at: %{mfa: {AshOnetime.Store.Postgres, :insert_payload, 4}}}, [
               :event,
               2,
               2,
               3
             ]), do: :payload
      end
      """,
      inspect_options: ~S"""
      defmodule FormatProbe do
        def probe(outcomes) do
          IO.inspect(%{
            outcomes: outcomes,
            source: :configured_formatter,
            first: :multiline_keyword_construct
          }, label: "FORMAT_PROBE", limit: :infinity)
        end
      end
      """
    ]

    for {name, input} <- inputs,
        {engine, formatter} <- [native: native, configured: configured] do
      first = formatter.(input)
      second = formatter.(first)
      third = formatter.(second)

      IO.inspect(
        %{
          fixture: name,
          engine: engine,
          first: first,
          second: second,
          first_stable?: first == second,
          second_stable?: second == third
        },
        label: "FORMATTER_PROBE",
        limit: :infinity
      )
    end
  end
end
