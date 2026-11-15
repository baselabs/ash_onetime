defmodule AshOnetime.DSTWindowTest do
  use ExUnit.Case, async: true

  test "POSIX DST windows cross exactly one transition on every leap and non-leap start day" do
    {output, status} =
      System.cmd("elixir", ["scripts/check_dst_windows.exs"], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "all 731 start dates, both day boundaries and both directions passed"
  end
end
