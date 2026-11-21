defmodule AshOnetime.ExternalState.LogicalURLTest do
  use ExUnit.Case, async: false
  alias AshOnetime.Test.LogicalReplicationCase

  setup do
    previous = System.get_env("ASH_ONETIME_LOGICAL_URL")

    on_exit(fn ->
      if previous,
        do: System.put_env("ASH_ONETIME_LOGICAL_URL", previous),
        else: System.delete_env("ASH_ONETIME_LOGICAL_URL")
    end)
  end

  test "missing logical URL fails closed" do
    System.delete_env("ASH_ONETIME_LOGICAL_URL")
    assert_raise System.EnvError, fn -> LogicalReplicationCase.logical_url!() end
  end

  test "the dedicated logical URL uses the same target guard as the main database" do
    for url <- [
          "ecto://postgres:postgres@localhost:18842/ash_onetime_test",
          "ecto://postgres:postgres@127.0.0.1:5432/ash_onetime_test",
          "ecto://other:postgres@127.0.0.1:18842/ash_onetime_test",
          "ecto://postgres:postgres@127.0.0.1:18842/other",
          "postgres://postgres:postgres@127.0.0.1:18842/ash_onetime_test"
        ] do
      System.put_env("ASH_ONETIME_LOGICAL_URL", url)
      assert_raise RuntimeError, fn -> LogicalReplicationCase.logical_url!() end
    end

    url = "ecto://postgres:postgres@127.0.0.1:18842/ash_onetime_test"
    System.put_env("ASH_ONETIME_LOGICAL_URL", url)
    assert LogicalReplicationCase.logical_url!() == url
  end

  test "csvlog parsing preserves quoted commas, newlines and escaped quotes" do
    assert LogicalReplicationCase.csv_records(~s(one,"two,three","a\nline","a""quote"\n)) ==
             [["one", "two,three", "a\nline", "a\"quote"]]

    assert LogicalReplicationCase.csv_records("incomplete,\"record") == []
  end
end
