defmodule AshOnetime.Test.DSTWindow do
  @moduledoc false

  # PostgreSQL 18 Appendix B.5 and src/timezone/localtime.c:getrule/transtime:
  # Jn ignores February 29; n counts it; Mm.w.d chooses a weekday occurrence.
  # Fixed dates use Jn, except February 29 itself, which must use n = 59.
  # /0 is prevailing local midnight: DST ends one hour before UTC midnight.
  # https://www.postgresql.org/docs/18/datetime-posix-timezone-specs.html
  # https://github.com/postgres/postgres/blob/REL_18_STABLE/src/timezone/localtime.c
  def build(%Date{} = today, direction) when direction in [:forward, :backward] do
    first = rule(Date.add(today, 4))
    second = rule(Date.add(today, 12))
    {start, finish} = if direction == :forward, do: {first, second}, else: {second, first}
    {"AOS0AOD-1,#{start}/0,#{finish}/0", 6 * 86_400}
  end

  defp rule(%Date{month: 2, day: 29}), do: "59"

  defp rule(date) do
    leap_day = if Calendar.ISO.leap_year?(date.year) and date.month > 2, do: 1, else: 0
    "J#{Date.day_of_year(date) - leap_day}"
  end
end
