defmodule AshOnetime.Test.ExitBoundary.Diagnostics do
  @moduledoc false

  # Captures and assertions keep their complete terms. Only this output boundary
  # projects them. In particular a credential copied out of its containing struct
  # is still private: scalar values never become printable by losing a field name.
  def render(value, options \\ []), do: inspect(safe(value), options)

  def logger_filter(event, _extra) do
    if private?(event) do
      %{event | msg: {:string, render(event.msg)}, meta: Map.take(event.meta, [:time, :gl, :pid])}
    else
      :ignore
    end
  end

  def status(status), do: Map.new(status, fn {key, value} -> {key, safe(value)} end)

  def safe(%Postgrex.Protocol{}), do: %{struct_type: Postgrex.Protocol, state: :private}

  def safe(%{__struct__: module}) when module in [DBConnection, DBConnection.ConnectionError],
    do: %{struct_type: module, state: :private}

  def safe(value) when is_binary(value),
    do: %{
      bytes: byte_size(value),
      sha256: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
    }

  def safe(value) when is_function(value),
    do: value |> Function.info() |> Map.new() |> Map.take([:module, :name, :arity, :index])

  def safe(value) when is_integer(value), do: %{type: :integer}
  def safe(value) when is_float(value), do: %{type: :float}
  def safe(value) when is_pid(value), do: :pid
  def safe(value) when is_port(value), do: :port
  def safe(value) when is_reference(value), do: :reference

  def safe(value) when is_list(value), do: safe_list(value, 12)

  def safe(value) when is_map(value) do
    Map.new(Map.to_list(value), fn {key, item} ->
      label = if key == :__struct__, do: :struct_type, else: safe(key)

      {label, field(key, item)}
    end)
  end

  def safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&safe/1) |> List.to_tuple()

  def safe(value), do: value

  def location(%{at: %{mfa: {module, function, arity}}}) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {^module, chunks}} <- :beam_lib.chunks(path, [:debug_info]),
         {:debug_info_v1, backend, data} <- chunks[:debug_info],
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []),
         {:attribute, _, :file, {file, _}} <-
           Enum.find(forms, &match?({:attribute, _, :file, _}, &1)),
         {:function, annotation, ^function, ^arity, _} <-
           Enum.find(forms, &match?({:function, _, ^function, ^arity, _}, &1)) do
      %{file: List.to_string(file), line: :erl_anno.line(annotation)}
    else
      _ -> %{mfa: {module, function, arity}, source: :native_or_generated}
    end
  end

  def location(error), do: %{at: safe(Map.get(error, :at))}

  # These are diagnostic coordinates, selected by their named fields. Actual,
  # expected, event, state, result and reason always take the private value route.
  defp field(key, value)
       when key in [:index, :run_index, :twin_index, :line, :arity, :offset, :length] and
              is_integer(value),
       do: value

  defp field(:path, path) when is_list(path),
    do: Enum.map(path, fn value -> if is_integer(value), do: value, else: safe(value) end)

  defp field(:mfa, {module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity),
       do: {module, function, arity}

  defp field(_key, value), do: safe(value)

  defp private?(%Postgrex.Protocol{}), do: true
  defp private?(%Postgrex.Query{}), do: true

  defp private?(value) when is_map(value) do
    Enum.any?(Map.to_list(value), fn {key, item} ->
      key in [:password, :url, :connection_key, :backend_key, :scram, :sock] or private?(item)
    end)
  end

  defp private?(value) when is_function(value),
    do: value |> Function.info(:env) |> elem(1) |> private?()

  defp private?({key, _value}) when key in [:password, :url, :connection_key, :backend_key, :scram],
    do: true

  defp private?(value) when is_tuple(value) and tuple_size(value) > 0 and elem(value, 0) == :sslsocket,
    do: true

  defp private?(value) when is_tuple(value), do: value |> Tuple.to_list() |> private?()
  defp private?([head | tail]), do: private?(head) or private?(tail)
  defp private?(_value), do: false

  defp safe_list([], _), do: []
  defp safe_list(_, 0), do: [:remaining]
  defp safe_list([head | tail], n), do: [safe(head) | safe_list(tail, n - 1)]
  defp safe_list(tail, _), do: [{:improper_tail, safe(tail)}]
end
