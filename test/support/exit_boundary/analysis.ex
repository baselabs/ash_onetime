defmodule AshOnetime.Test.ExitBoundary.Analysis do
  @moduledoc false

  # Rule 3 searches and class coverage. Rule 4 compares the complete observation in
  # Comparator; there is no projection, region filter, or multiset in this module.
  def unclaimed(events) do
    for %{class: :unclaimed} = event <- events, uniq: true, do: descriptor(event)
  end

  def descriptor(%{class: class, mfa: {m, f, a}}), do: {class, m, f, a}
  def descriptor(%{class: class, event: event}), do: {class, elem(event, 1)}

  def hits(events, needles, allowed?) do
    for event <- events,
        not allowed?.(event),
        contains?(event.event, needles),
        uniq: true,
        do: descriptor(event)
  end

  @doc """
  The needles of each secret: raw, Base64 (standard and URL, padded or not), Base16, and
  the secret as an unsigned integer in both byte orders where it fits a 64-bit word (an
  atomic or a counter carries integers only).
  """
  def needles(secrets) do
    Enum.flat_map(Enum.reject(secrets, &(&1 == <<>>)), fn secret ->
      [
        secret,
        Base.encode64(secret),
        Base.encode64(secret, padding: false),
        Base.url_encode64(secret),
        Base.url_encode64(secret, padding: false),
        Base.encode16(secret),
        Base.encode16(secret, case: :lower)
      ] ++ integers(secret)
    end)
    |> Enum.uniq()
  end

  defp integers(secret) when byte_size(secret) <= 8,
    do: [:binary.decode_unsigned(secret, :big), :binary.decode_unsigned(secret, :little)]

  defp integers(_secret), do: []

  @doc "Whether `term` carries any of `needles`, through binaries, iodata, atoms and closures."
  def contains?(term, needles) when is_binary(term),
    do: Enum.any?(needles, &(is_binary(&1) and :binary.match(term, &1) != :nomatch))

  def contains?(term, needles) when is_integer(term), do: term in needles

  def contains?(term, needles) when is_atom(term),
    do: contains?(Atom.to_string(term), needles)

  def contains?(term, needles) when is_list(term) do
    iodata_contains?(term, needles) or Enum.any?(proper(term), &contains?(&1, needles))
  end

  def contains?(term, needles) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains?(needles)

  def contains?(%{} = term, needles),
    do:
      term
      |> Map.to_list()
      |> Enum.any?(fn {k, v} -> contains?(k, needles) or contains?(v, needles) end)

  def contains?(term, needles) when is_function(term) do
    {:env, env} = :erlang.fun_info(term, :env)
    contains?(env, needles)
  end

  def contains?(term, needles) when is_bitstring(term) do
    size = bit_size(term) - rem(bit_size(term), 8)
    <<bytes::bitstring-size(^size), _::bitstring>> = term
    contains?(bytes, needles)
  end

  def contains?(_term, _needles), do: false

  defp iodata_contains?(list, needles) do
    contains?(IO.iodata_to_binary(list), needles)
  rescue
    ArgumentError -> false
  end

  defp proper(list) do
    case improper_split(list, []) do
      {items, []} -> items
      {items, tail} -> [tail | items]
    end
  end

  defp improper_split([head | tail], acc), do: improper_split(tail, [head | acc])
  defp improper_split(tail, acc), do: {acc, tail}
end
