defmodule AshOnetime.MutationFormatterFailureTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.MutationFormatter
  Code.require_file("../scripts/mutation_failures.exs", __DIR__)

  test "a task crash is recorded without attributing it to an assertion" do
    test = %ExUnit.Test{
      name: :"test task failure",
      tags: %{file: __ENV__.file},
      state: {:failed, [{{:EXIT, self()}, {{:badmatch, :rollback}, []}, []}]}
    }

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:noreply, nil} =
                 MutationFormatter.handle_cast({:test_finished, test}, nil)
      end)

    assert [%{"test_name" => "task failure", "line" => 0}] =
             AshOnetime.MutationFailures.records(output)

    refute AshOnetime.MutationFailures.matches?(
             AshOnetime.MutationFailures.records(output),
             %{test: __ENV__.file, assertion_line: 42},
             "task failure",
             "assert"
           )
  end
end
