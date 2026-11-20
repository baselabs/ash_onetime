defmodule AshOnetime.Test.ExitBoundary.Values do
  @moduledoc false
  import Bitwise

  def set do
    a = %{short: :crypto.strong_rand_bytes(8), long: :crypto.strong_rand_bytes(32)}
    bits = %{short: :rand.uniform(64) - 1, long: :rand.uniform(256) - 1}
    Process.put({__MODULE__, :flipped_bits}, bits)

    [
      {:va, a},
      {:vb, Map.new(a, fn {k, v} -> {k, for(<<b <- v>>, into: <<>>, do: <<bxor(b, 255)>>)} end)},
      {:vc, Map.new(a, fn {k, v} -> {k, flip(v, bits[k])} end)},
      {:vd, %{short: :crypto.strong_rand_bytes(8), long: :crypto.strong_rand_bytes(33)}},
      {:ve, %{short: :crypto.strong_rand_bytes(8), long: :crypto.strong_rand_bytes(65_536)}},
      {:vf, %{short: :crypto.strong_rand_bytes(8), long: <<>>}}
    ]
  end

  def flipped_bits, do: Process.get({__MODULE__, :flipped_bits})

  defp flip(value, at) do
    <<head::bitstring-size(^at), b::1, tail::bitstring>> = value
    <<head::bitstring, bxor(b, 1)::1, tail::bitstring>>
  end
end
