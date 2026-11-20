defmodule AshOnetime.Test.ExitBoundary.AttributeCopies do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Registry
  @source {AshOnetime.Admission, :reject_reserved, 1}
  @reader {AshOnetime.Admission, :reserved_surface?, 1}
  @callback_frame {AshOnetime.Admission, :"-reserved_surface?/1-fun-0-", 2}

  # reject_reserved enumerates these source fields in this order. Bind copies to
  # that enumeration, including callbacks, rather than recognizing map keys.
  def build(indexed, resource) do
    typed = Registry.uuid_attributes(resource)
    initial = %{active: %{}, slots: %{}}

    Enum.reduce(indexed.events, initial, fn e, s ->
      case e.event do
        {pid, :call, {AshOnetime.Admission, :reject_reserved, [subject]}} ->
          fields =
            if is_struct(subject, Ash.Changeset),
              do: [:attributes, :params, :arguments],
              else: [:params, :arguments]

          sources =
            Enum.map(fields, fn field ->
              %{
                value: Map.get(subject, field, %{}),
                typed: if(field == :attributes, do: typed, else: [])
              }
            end)

          put_in(s.active[pid], %{sources: sources, ordinal: 0, current: nil})

        {pid, :call, {AshOnetime.Admission, :reserved_surface?, [_]}} ->
          case Map.get(s.active, pid) do
            nil ->
              s

            frame ->
              source = Enum.at(frame.sources, frame.ordinal)
              s = put_in(s.slots[{e.index, 0}], source)
              put_in(s.active[pid], %{frame | ordinal: frame.ordinal + 1, current: source})
          end

        {pid, :call, {AshOnetime.Admission, :"-reserved_surface?/1-fun-0-", [_, _]}} ->
          case Map.get(s.active, pid) do
            %{current: source} -> put_in(s.slots[{e.index, 1}], source)
            nil -> s
          end

        {pid, :return_from, @source, _} ->
          %{s | active: Map.delete(s.active, pid)}

        _ ->
          s
      end
    end)
    |> Map.fetch!(:slots)
  end

  def slot(%{mfa: mfa}, [:event, 2, 2, argument])
      when (mfa == @reader and argument == 0) or (mfa == @callback_frame and argument == 1),
      do: argument

  def slot(_, _), do: nil
end
