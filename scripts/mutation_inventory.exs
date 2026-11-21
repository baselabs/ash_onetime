defmodule AshOnetime.MutationInventory do
  @moduledoc false

  @marker ~r/^[\t ]*(?:--|#)[\t ]*rule:([a-zA-Z0-9_-]+)[^\n]*$/m
  # rule:inventory-unmarked-reraise
  @enforcer ~r/\bRAISE\b|\bNEW\.[a-z_]+\s*:=|\b(?:CHECK\s*\(|PRIMARY\s+KEY\b|FOREIGN\s+KEY\b|CREATE\s+POLICY\b|ENABLE\s+ALWAYS\s+TRIGGER\b|SECURITY\s+(?:DEFINER|INVOKER|%s)\b|SET\s+search_path\b|FOR\s+(?:NO\s+KEY\s+UPDATE|KEY\s+SHARE|UPDATE|SHARE)\b)|CASE\s+WHEN\s+owner_only\b/i
  @row_lock ~r/\bFOR\s+(?:NO\s+KEY\s+UPDATE\b|KEY\s+SHARE\b|UPDATE\b|SHARE\b|#\{[a-z_][a-z_0-9]*\})/i
  @classifier ~r/^(?:classify(?:_|$)|effect_state$|decide$|collision_result$|loaded_result$|resolve_locked_claim$)/

  def canonical_sources do
    (Path.wildcard("priv/templates/migrations/**/*.{exs,sql}") ++
       Path.wildcard("lib/ash_onetime/**/*.ex") ++
       Path.wildcard("lib/mix/tasks/ash_onetime.*.ex"))
    |> Map.new(&{&1, File.read!(&1)})
  end

  def marker_errors(manifest, sources) do
    sites = Enum.flat_map(sources, fn {path, source} -> marked_spans(path, source) end)

    duplicate_errors =
      sites
      |> Enum.group_by(& &1.id)
      |> Enum.flat_map(fn {id, marked} ->
        if length(marked) == 1,
          do: [],
          else: ["rule:#{id} marks #{length(marked)} canonical sites"]
      end)

    row_errors = Enum.flat_map(sites, &row_errors(&1, manifest))
    marked_ids = MapSet.new(sites, & &1.id)

    orphan_errors =
      Enum.flat_map(manifest, fn {id, row} ->
        if Map.has_key?(sources, row.path) and not MapSet.member?(marked_ids, id),
          do: ["manifest row #{id} has no marker in #{row.path}"],
          else: []
      end)

    Enum.sort(duplicate_errors ++ row_errors ++ orphan_errors)
  end

  def assert_markers!(manifest, sources) do
    refuse!(marker_errors(manifest, sources))
  end

  def assert_rendered!(manifest, sources, rendered) do
    errors = marker_errors(manifest, sources) ++ elixir_errors(sources)

    rendered_errors =
      Enum.flat_map(rendered, fn {label, source} ->
        source
        |> Code.string_to_quoted!()
        |> literals()
        |> Enum.uniq()
        |> Enum.flat_map(fn sql ->
          rendered_marker_errors(label, sql, manifest) ++ unmarked_enforcers(label, sql)
        end)
      end)

    routine_errors =
      Enum.flat_map(rendered, fn {label, source} -> routine_errors(label, source) end)

    refuse!(Enum.sort(Enum.uniq(errors ++ rendered_errors ++ routine_errors)))
  end

  def routines(rendered) do
    ast = Code.string_to_quoted!(rendered)

    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{:maintenance_functions, _, [value]}]} = node, _acc -> {node, value}
        node, acc -> {node, acc}
      end)

    if found do
      {routines, []} = Code.eval_quoted(found)
      routines
    else
      []
    end
  end

  def assert_catalog!(expected, actual) do
    differences =
      Enum.flat_map(expected, fn {kind, values} ->
        # rule:inventory-catalog-equality
        if Map.fetch!(actual, kind) == values,
          do: [],
          else: ["live #{kind} differs from rendered template inventory"]
      end)

    refuse!(differences)
  end

  defp row_errors(site, manifest) do
    case Map.fetch(manifest, site.id) do
      :error ->
        # rule:inventory-missing-row
        ["rule:#{site.id} has no manifest row at #{site.path}:#{site.line}"]

      {:ok, row} ->
        cond do
          row.path != site.path ->
            ["rule:#{site.id} manifest path differs from #{site.path}"]

          not String.contains?(site.span, row.original) ->
            ["rule:#{site.id} original is outside its marked span at #{site.path}:#{site.line}"]

          true ->
            []
        end
    end
  end

  defp marked_spans(path, source) do
    matches = Regex.scan(@marker, source, return: :index)

    Enum.map(matches, fn [{start, length}, {id_start, id_length}] ->
      next =
        Enum.find(matches, fn [{offset, _} | _] ->
          offset > start and not comment_gap?(source, start + length, offset)
        end)

      id = binary_part(source, id_start, id_length)

      explicit_end =
        :binary.match(source, "-- end-rule:" <> id, scope: {start, byte_size(source) - start})

      finish =
        case explicit_end do
          {offset, size} -> offset + size
          :nomatch -> if next, do: next |> hd() |> elem(0), else: byte_size(source)
        end

      %{
        id: binary_part(source, id_start, id_length),
        path: path,
        line: line(source, start),
        span: binary_part(source, start, finish - start)
      }
    end)
  end

  defp comment_gap?(source, from, to) do
    source |> binary_part(from, to - from) |> String.trim() == ""
  end

  defp unmarked_enforcers(label, sql) do
    markers = Regex.scan(@marker, sql, return: :index)
    # rule:inventory-unmarked-enforcer
    sites = Regex.scan(@enforcer, sql, return: :index)
    unmarked_sites(label, sql, markers, sites)
  end

  defp rendered_marker_errors(label, source, manifest) do
    Enum.flat_map(Regex.scan(@marker, source), fn [_, id] ->
      if Map.has_key?(manifest, id),
        do: [],
        else: ["rendered rule:#{id} has no manifest row in #{label}"]
    end)
  end

  defp unmarked_sites(label, source, markers, sites) do
    Enum.flat_map(sites, fn [{offset, size}] ->
      previous = markers |> Enum.filter(fn [{start, _} | _] -> start < offset end) |> List.last()

      earlier =
        Enum.any?(sites, fn [{start, _}] ->
          start < offset and
            (is_nil(previous) or start > previous |> hd() |> elem(0))
        end)

      if is_nil(previous) or earlier do
        [
          "unmarked enforcing site in #{label}:#{line(source, offset)}: #{binary_part(source, offset, size)}"
        ]
      else
        []
      end
    end)
  end

  defp elixir_errors(sources) do
    Enum.flat_map(sources, fn {path, source} ->
      if String.ends_with?(path, ".ex") do
        ast = Code.string_to_quoted!(source, columns: true, token_metadata: true)

        {_, clauses} =
          Macro.prewalk(ast, [], fn
            {kind, meta, [head, body]} = node, acc when kind in [:def, :defp] ->
              name = head_name(head)

              if Regex.match?(@classifier, Atom.to_string(name)) do
                {_, branches} =
                  Macro.prewalk(body, [], fn
                    {:->, branch_meta, _} = branch, found ->
                      {branch, [branch_meta | found]}

                    branch, found ->
                      {branch, found}
                  end)

                {node, if(branches == [], do: [meta], else: branches) ++ acc}
              else
                {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        sites =
          Enum.map(clauses, fn meta ->
            offset = line_offset(source, meta[:line]) + meta[:column] - 1
            [{offset, 1}]
          end) ++
            Enum.reject(Regex.scan(@row_lock, source, return: :index), fn [{offset, _}] ->
              beginning = line_offset(source, line(source, offset))
              prefix = binary_part(source, beginning, offset - beginning)
              String.starts_with?(String.trim_leading(prefix), "#")
            end)

        unmarked_sites(path, source, Regex.scan(@marker, source, return: :index), sites)
      else
        []
      end
    end)
  end

  defp head_name({:when, _, [head | _]}), do: head_name(head)
  defp head_name({name, _, _}), do: name

  defp routine_errors(label, source) do
    Enum.flat_map(routines(source), fn routine ->
      Enum.flat_map([:security, :settings], fn field ->
        value = Map.fetch!(routine, field)

        if is_binary(value) and Regex.match?(@marker, value) do
          []
        else
          ["unmarked routine #{field} in #{label}: #{routine.name}"]
        end
      end)
    end)
  end

  defp line_offset(source, number) do
    source
    |> String.split("\n")
    |> Enum.take(number - 1)
    |> Enum.reduce(0, fn line, size -> size + byte_size(line) + 1 end)
  end

  defp literals(ast) do
    {_, strings} =
      Macro.prewalk(ast, [], fn
        {:<<>>, _, parts}, acc ->
          value =
            Enum.map_join(parts, fn
              part when is_binary(part) -> part
              _interpolation -> "__interpolated__"
            end)

          nested =
            Enum.flat_map(parts, fn
              part when is_binary(part) -> []
              expression -> literals(expression)
            end)

          {nil, [value | nested ++ acc]}

        value, acc when is_binary(value) ->
          {value, [value | acc]}

        node, acc ->
          {node, acc}
      end)

    strings
  end

  defp line(source, offset), do: 1 + length(:binary.matches(binary_part(source, 0, offset), "\n"))

  defp refuse!([]), do: :ok
  defp refuse!(errors), do: raise("mutation inventory refused:\n" <> Enum.join(errors, "\n"))
end
