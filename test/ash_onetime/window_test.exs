defmodule AshOnetime.WindowTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Window

  @evaluated_at ~U[2026-08-04 12:00:00.000000Z]

  @tag :window_mutation
  test "oldest replay-window endpoint is inclusive" do
    oldest = DateTime.add(@evaluated_at, -65, :second)
    assert :ok = Window.validate(oldest, nil, @evaluated_at, 60, 5)
  end

  test "one microsecond older than the oldest endpoint is invalid" do
    oldest = DateTime.add(@evaluated_at, -65, :second)
    assert {:error, :invalid} = Window.validate(tick(oldest, -1), nil, @evaluated_at, 60, 5)
  end

  test "newest replay-window endpoint is inclusive and the next tick is invalid" do
    newest = DateTime.add(@evaluated_at, 5, :second)
    assert :ok = Window.validate(newest, nil, @evaluated_at, 60, 5)
    assert {:error, :invalid} = Window.validate(tick(newest, 1), nil, @evaluated_at, 60, 5)
  end

  test "expiry is ordered and inclusive through skew" do
    issued_at = DateTime.add(@evaluated_at, -10, :second)
    expires_at = DateTime.add(@evaluated_at, -5, :second)

    assert :ok = Window.validate(issued_at, expires_at, @evaluated_at, 60, 5)

    assert {:error, :invalid} =
             Window.validate(issued_at, tick(expires_at, -1), @evaluated_at, 60, 5)

    assert {:error, :invalid} =
             Window.validate(issued_at, tick(issued_at, -1), @evaluated_at, 60, 5)
  end

  test "cleanup returns the first DateTime strictly after the inclusive horizon" do
    issued_at = ~U[2026-08-04 11:58:55.000000Z]
    replay_horizon = DateTime.add(issued_at, 65, :second)
    cleanup_at = Window.cleanup_after(issued_at, 60, 5)

    assert %DateTime{} = cleanup_at
    assert cleanup_at == tick(replay_horizon, 1)
    assert DateTime.compare(cleanup_at, replay_horizon) == :gt
  end

  test "invalid duration and timestamp inputs fail closed" do
    assert {:error, :invalid} = Window.validate(@evaluated_at, nil, @evaluated_at, -1, 0)
    assert {:error, :invalid} = Window.validate(@evaluated_at, nil, @evaluated_at, 1, -1)
    assert {:error, :invalid} = Window.validate(:not_a_time, nil, @evaluated_at, 1, 0)
    assert {:error, :invalid} = Window.cleanup_after(@evaluated_at, -1, 0)
    assert {:error, :invalid} = Window.cleanup_after(:not_a_time, 1, 0)
  end

  test "duration magnitudes and their sum are bounded symmetrically" do
    maximum = 2_147_483_647

    assert :ok = Window.validate(@evaluated_at, nil, @evaluated_at, maximum, 0)
    assert :ok = Window.validate(@evaluated_at, nil, @evaluated_at, 0, maximum)
    assert %DateTime{} = Window.cleanup_after(@evaluated_at, maximum, 0)

    assert {:error, :invalid} =
             Window.validate(@evaluated_at, nil, @evaluated_at, maximum + 1, 0)

    assert {:error, :invalid} =
             Window.validate(@evaluated_at, nil, @evaluated_at, 0, maximum + 1)

    assert {:error, :invalid} =
             Window.validate(@evaluated_at, nil, @evaluated_at, maximum, 1)

    assert {:error, :invalid} = Window.cleanup_after(@evaluated_at, maximum + 1, 0)
    assert {:error, :invalid} = Window.cleanup_after(@evaluated_at, 0, maximum + 1)
    assert {:error, :invalid} = Window.cleanup_after(@evaluated_at, maximum, 1)
  end

  test "malformed DateTime structs fail closed without raising" do
    malformed = %{@evaluated_at | month: 13}

    assert {:error, :invalid} = Window.validate(malformed, nil, @evaluated_at, 60, 5)
    assert {:error, :invalid} = Window.validate(@evaluated_at, malformed, @evaluated_at, 60, 5)
    assert {:error, :invalid} = Window.validate(@evaluated_at, nil, malformed, 60, 5)
    assert {:error, :invalid} = Window.cleanup_after(malformed, 60, 5)
  end

  defp tick(datetime, amount), do: DateTime.add(datetime, amount, :microsecond)
end
