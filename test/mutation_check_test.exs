defmodule AshOnetime.MutationCheckTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Test.MutationFormatter

  Code.require_file("../scripts/mutation_failures.exs", __DIR__)

  @tag :mutation_checker_attribution_mutation
  test "failure attribution refuses a name and assertion from different failures" do
    mutation = %{test: "test/owned_test.exs", assertion_line: 42}

    records = [
      %{"test_name" => "owned case", "file" => "test/owned_test.exs", "line" => 23},
      %{"test_name" => "other case", "file" => "test/owned_test.exs", "line" => 42}
    ]

    refute AshOnetime.MutationFailures.matches?(
             records,
             mutation,
             "owned case",
             "assert protected"
           )

    refute AshOnetime.MutationFailures.matches?(
             [%{"test_name" => "owned case", "file" => "test/other_test.exs", "line" => 42}],
             mutation,
             "owned case",
             "assert protected"
           )

    assert AshOnetime.MutationFailures.matches?(
             [%{"test_name" => "owned case", "file" => "test/owned_test.exs", "line" => 42}],
             mutation,
             "owned case",
             "assert protected"
           )
  end

  test "structured failure records start after formatter progress output" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        IO.write(".")

        test = %ExUnit.Test{
          name: :"test owned case",
          tags: %{file: __ENV__.file},
          state:
            {:failed,
             [
               {:error, %ExUnit.AssertionError{message: "assert protected"},
                [{__MODULE__, :example, 1, [file: __ENV__.file, line: 42]}]}
             ]}
        }

        MutationFormatter.handle_cast({:test_finished, test}, nil)
      end)

    assert [%{"test_name" => "owned case", "line" => 42}] =
             AshOnetime.MutationFailures.records(output)
  end

  test "structured failure formatter records the assertion location of a real failure" do
    directory = Path.join(System.tmp_dir!(), "ao_formatter_#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    path = Path.join(directory, "owned_test.exs")

    File.write!(
      path,
      "defmodule FormatterProbe do\n  use ExUnit.Case\n  test \"owned case\" do\n    assert 1 == 2\n  end\nend\n"
    )

    try do
      {output, status} =
        System.cmd(
          "mix",
          [
            "test",
            path,
            "--formatter",
            "AshOnetime.Test.MutationFormatter",
            "--formatter",
            "ExUnit.CLIFormatter"
          ],
          stderr_to_stdout: true
        )

      assert status == 2, output

      assert [%{"test_name" => "owned case", "file" => file, "line" => 4}] =
               AshOnetime.MutationFailures.records(output)

      assert Path.expand(file) == path
    after
      File.rm_rf!(directory)
    end
  end

  @tag :mutation_checker_execution_proof_mutation
  @tag :mutation_checker_source_site_mutation
  test "mutation checker self-test proves restoration requires an executed ExUnit result" do
    {output, status} =
      System.cmd(
        "mix",
        ["run", "scripts/check_mutations.exs", "--self-test"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert output =~
             "mutation checker self-test: every registered mutation has exactly one source site"

    assert output =~ "mutation checker self-test: restoration requires an executed ExUnit result"

    assert output =~
             "mutation checker self-test: every shard count partitions the battery exactly"
  end
end
