defmodule AshOnetime.Test.ExitBoundary.Declarations do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Registry

  def pair(run, twin) do
    left = Registry.declarations(run)
    right = Registry.declarations(twin)

    slots =
      for {reader, a} <- left,
          {path, av, bv} <- differences(a, right[reader]),
          do: %{reader: reader, path: path, run: av, twin: bv}

    declared = Registry.declaration_slots()
    actual = MapSet.new(slots, &{&1.reader, &1.path})
    missing = for slot <- slots, not MapSet.member?(declared, {slot.reader, slot.path}), do: slot

    dead =
      for {reader, path} <- MapSet.difference(declared, actual),
          do: %{
            reader: reader,
            path: path,
            run: :dead_declaration_slot,
            twin: :differing_compiled_field
          }

    errors = missing ++ dead
    %{run: left, twin: right, slots: slots, errors: errors}
  end

  def differences(a, b, path \\ [])
  def differences(a, b, _path) when a === b, do: []

  def differences(a, b, path) when is_map(a) and is_map(b) do
    keys = (Map.keys(a) ++ Map.keys(b)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(keys, fn key ->
      case {Map.fetch(a, key), Map.fetch(b, key)} do
        {{:ok, av}, {:ok, bv}} -> differences(av, bv, path ++ [key])
        {av, bv} -> [{path ++ [key], av, bv}]
      end
    end)
  end

  def differences(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    Enum.zip(a, b)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} -> differences(x, y, path ++ [i]) end)
  end

  def differences(a, b, path) when is_tuple(a) and is_tuple(b) and tuple_size(a) == tuple_size(b),
    do: differences(Tuple.to_list(a), Tuple.to_list(b), path)

  def differences(a, b, path), do: [{path, a, b}]
end
