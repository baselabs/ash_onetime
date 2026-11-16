Code.require_file("../test/support/dst_window.ex", __DIR__)

defmodule AshOnetime.DSTWindowCheck do
  @moduledoc false

  def run do
    for year <- [2027, 2028],
        date <- Date.range(Date.new!(year, 1, 1), Date.new!(year, 12, 31)),
        time <- [~T[00:00:00], ~T[23:59:59.999999]],
        direction <- [:forward, :backward] do
      check!(date, time, direction)
    end

    IO.puts(
      "DST window check: all 731 start dates, both day boundaries and both directions passed"
    )
  end

  defp check!(date, time, direction) do
    {zone, seconds} = AshOnetime.Test.DSTWindow.build(date, direction)
    ["AOS0AOD-1", start_rule, end_rule] = String.split(zone, ",")
    now = DateTime.new!(date, time)
    deadline = DateTime.add(now, seconds)

    transitions =
      for year <- (date.year - 1)..(date.year + 2),
          {rule, kind, offset} <- [{start_rule, :forward, 0}, {end_rule, :backward, -3600}] do
        {rule |> rule_date(year) |> DateTime.new!(~T[00:00:00]) |> DateTime.add(offset), kind}
      end

    crossed =
      Enum.filter(transitions, fn {instant, _kind} ->
        DateTime.compare(instant, now) == :gt and DateTime.compare(instant, deadline) != :gt
      end)

    case crossed do
      [{instant, ^direction}] ->
        expected_date = Date.add(date, 4)
        expected_offset = if direction == :backward, do: -3600, else: 0
        expected = DateTime.add(DateTime.new!(expected_date, ~T[00:00:00]), expected_offset)
        unless instant == expected, do: raise("wrong transition for #{date}: #{zone}")

      _ ->
        raise "window must cross exactly one #{direction} transition for #{date}: #{zone}"
    end

    following =
      transitions
      |> Enum.filter(fn {instant, _} -> DateTime.compare(instant, now) == :gt end)
      |> Enum.sort_by(fn {instant, _} -> DateTime.to_unix(instant) end)
      |> Enum.take(2)

    [{_, ^direction}, {second, other}] = following
    expected_other = if direction == :forward, do: :backward, else: :forward
    expected_offset = if other == :backward, do: -3600, else: 0
    expected = DateTime.add(DateTime.new!(Date.add(date, 12), ~T[00:00:00]), expected_offset)

    unless other == expected_other and second == expected and
             DateTime.compare(deadline, second) == :lt do
      raise "wrong following transition for #{date}: #{zone}"
    end
  end

  defp rule_date("J" <> rule, year) do
    {day, "/0"} = Integer.parse(rule)
    leap_day = if Calendar.ISO.leap_year?(year) and day >= 60, do: 1, else: 0
    Date.add(Date.new!(year, 1, 1), day - 1 + leap_day)
  end

  defp rule_date(rule, year) do
    {day, "/0"} = Integer.parse(rule)
    Date.add(Date.new!(year, 1, 1), day)
  end
end

AshOnetime.DSTWindowCheck.run()
