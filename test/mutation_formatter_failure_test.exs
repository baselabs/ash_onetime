defmodule AshOnetime.MutationFormatterFailureTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.MutationFormatter
  alias AshOnetime.Test.TestFormatter
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

  test "a failure expression selects source without printing runtime assertion terms" do
    secret = "formatter-runtime-sentinel"

    {error, stack} =
      try do
        assert secret == :expected
      rescue
        error in ExUnit.AssertionError -> {error, __STACKTRACE__}
      end

    test = %ExUnit.Test{name: :"test expression source", tags: %{file: __ENV__.file}}
    record = TestFormatter.failure(test, error, stack)
    assert record.assertion == "assert secret == :expected"
    assert TestFormatter.failure(test, error, []).assertion == record.assertion
    refute record.assertion =~ secret

    # The expression is used only as a lookup into parsed source. An arbitrary
    # runtime expression can neither manufacture source nor expose its values.
    foreign = %{error | expr: {:assert, [], [secret]}}
    unattributed = TestFormatter.failure(test, foreign, [])
    assert unattributed.assertion == "source assertion unavailable"
    assert unattributed.line == 0
  end
end
