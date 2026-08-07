defmodule AshOnetime.WindowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  @tag :window_newest_mutation
  test "newest replay-window endpoint is inclusive and the next tick is invalid" do
    newest = DateTime.add(@evaluated_at, 5, :second)
    assert :ok = Window.validate(newest, nil, @evaluated_at, 60, 5)
    assert {:error, :invalid} = Window.validate(tick(newest, 1), nil, @evaluated_at, 60, 5)
  end

  @tag :window_expiry_horizon_mutation
  test "expiry is ordered and inclusive through skew" do
    issued_at = DateTime.add(@evaluated_at, -10, :second)
    expires_at = DateTime.add(@evaluated_at, -5, :second)

    # expiry_horizon == evaluated_at here (expires_at + skew), the inclusive horizon edge
    assert :ok = Window.validate(issued_at, expires_at, @evaluated_at, 60, 5)

    assert {:error, :invalid} =
             Window.validate(issued_at, tick(expires_at, -1), @evaluated_at, 60, 5)

    assert {:error, :invalid} =
             Window.validate(issued_at, tick(issued_at, -1), @evaluated_at, 60, 5)
  end

  @tag :window_expiry_order_mutation
  test "an expiry equal to issuance is the inclusive ordering edge and accepts" do
    # Evaluated at issuance so the horizon is not tripped; expires_at == issued_at exercises the
    # `compare(expires_at, issued_at) in [:eq, :gt]` inclusive ordering edge.
    assert :ok = Window.validate(@evaluated_at, @evaluated_at, @evaluated_at, 60, 5)

    # one microsecond before issuance falls outside the ordering and rejects
    assert {:error, :invalid} =
             Window.validate(@evaluated_at, tick(@evaluated_at, -1), @evaluated_at, 60, 5)
  end

  test "a zero-width window admits only the exact evaluation instant" do
    assert :ok = Window.validate(@evaluated_at, nil, @evaluated_at, 0, 0)
    assert {:error, :invalid} = Window.validate(tick(@evaluated_at, -1), nil, @evaluated_at, 0, 0)
    assert {:error, :invalid} = Window.validate(tick(@evaluated_at, 1), nil, @evaluated_at, 0, 0)
  end

  property "validate agrees with the interval arithmetic over generated windows" do
    check all(
            issued_offset <- integer(-200..200),
            max_age <- integer(0..120),
            skew <- integer(0..30)
          ) do
      issued_at = DateTime.add(@evaluated_at, issued_offset, :second)

      # The acceptance predicate, computed independently of Window: issuance within
      # [evaluated - (max_age + skew), evaluated + skew], inclusive.
      within? = issued_offset >= -(max_age + skew) and issued_offset <= skew

      case Window.validate(issued_at, nil, @evaluated_at, max_age, skew) do
        :ok -> assert within?
        {:error, :invalid} -> refute within?
      end
    end
  end

  test "cleanup horizon clears the replay horizon by the clock-skew retention margin" do
    issued_at = ~U[2026-08-04 11:58:55.000000Z]
    replay_horizon = DateTime.add(issued_at, 65, :second)
    cleanup_at = Window.cleanup_after(issued_at, 60, 5)
    margin = Window.cleanup_skew_margin_seconds()

    assert %DateTime{} = cleanup_at
    # The nonce stays retained for the full margin PAST the acceptance horizon, so a
    # cleanup evaluated on the PostgreSQL clock cannot delete a nonce the acceptance
    # window (application clock) still accepts, given app<->DB skew below the margin.
    assert margin >= 1
    assert cleanup_at == DateTime.add(replay_horizon, margin, :second)
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
