defmodule AshOnetime.MutationCheckTest do
  use ExUnit.Case, async: false

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
  end
end
