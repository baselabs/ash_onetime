defmodule AshOnetime.Test.ExitBoundary.Diagnostics do
  @moduledoc false

  # Captures and comparisons keep complete terms. Diagnostics must not print
  # producer bytes, connection secrets, or a closure's captured values.
  def safe(value) when is_binary(value),
    do: %{bytes: byte_size(value), sha256: Base.encode16(:crypto.hash(:sha256, value), case: :lower)}
  def safe(value) when is_function(value),
    do: value |> Function.info() |> Map.new() |> Map.take([:module, :name, :arity, :index])
  def safe(value) when is_list(value), do: safe_list(value, 12)
  def safe(value) when is_map(value) do
    Map.new(Map.to_list(value), fn {key, item} ->
      label = if key == :__struct__, do: :struct_type, else: safe(key)
      {label, if(key in [:password, :url, :secret, :scram, :connection_key],
        do: :redacted, else: safe(item))}
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
         {:attribute, _, :file, {file, _}} <- Enum.find(forms, &match?({:attribute, _, :file, _}, &1)),
         {:function, annotation, ^function, ^arity, _} <- Enum.find(forms, &match?({:function, _, ^function, ^arity, _}, &1)) do
      %{file: List.to_string(file), line: :erl_anno.line(annotation)}
    else
      _ -> %{mfa: {module, function, arity}, source: :native_or_generated}
    end
  end
  def location(error), do: %{at: Map.get(error, :at)}

  defp safe_list([], _), do: []
  defp safe_list(_, 0), do: [:remaining]
  defp safe_list([head | tail], n), do: [safe(head) | safe_list(tail, n - 1)]
  defp safe_list(tail, _), do: [{:improper_tail, safe(tail)}]
end
