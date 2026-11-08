defmodule AshOnetime.Boundary.Query do
  @moduledoc """
  The context-boundary query expression and its validation.

  A query is a boolean expression over tags and types — `{:tag, t}`, `{:type, t}`,
  `{:any, [branch]}`, `{:all, [branch]}`, `{:not, inner}` — with branches as lists of
  expressions. Validation enforces the package's size bounds and **tag-anchoring**:
  every fact the query can match carries at least one tag the query names, which is
  what makes `AshOnetime.Boundary.append_if/5`'s advisory-lock set cover the context
  (any concurrent writer whose fact matches must lock one of those tags). A query
  naming no tag — or whose matches could be satisfied by a type branch or a negation
  alone — is refused.
  """

  # Validation and SQL compilation for context-boundary queries: a boolean
  # expression over tags and types. Validation enforces three properties:
  #
  #   * bounds — node count, tag-leaf count, and depth stay inside package
  #     ceilings, so a query can never ask for an unbounded number of advisory
  #     locks or an unboundedly deep predicate;
  #   * bounded leaves — every tag and type is a 1..255-byte UTF-8 binary
  #     without NUL bytes;
  #   * tag-anchoring (soundness) — every fact the query can match carries at
  #     least one tag the query names. This is what makes the lock set cover
  #     the context: any concurrent writer whose fact matches the query must
  #     lock one of those named tags (writers lock every tag their query names
  #     and every tag their facts carry), so the check and append serialize
  #     against exactly the writers that could change the context. A query
  #     naming no tag — or whose matches could be satisfied by a type branch
  #     or a negation alone — is refused.

  @max_nodes 64
  @max_tag_leaves 32
  @max_depth 8
  @max_leaf_bytes 255
  @unanchored "context query must name at least one tag"

  defstruct [:expr, :tags]

  @type leaf :: binary()
  @type t :: %__MODULE__{expr: expr(), tags: [binary()]}
  @type expr ::
          {:tag, leaf()}
          | {:type, leaf()}
          | {:any, [expr()]}
          | {:all, [expr()]}
          | {:not, expr()}

  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(input) do
    with {:ok, expr, _counts} <- walk(input, 0, %{nodes: 0, tag_leaves: 0}),
         :ok <- anchored?(expr) do
      tags = collect_tags(expr, []) |> Enum.uniq() |> Enum.sort()
      {:ok, %__MODULE__{expr: expr, tags: tags}}
    end
  end

  @doc """
  Compiles the validated expression into a parameterized SQL predicate.

  `start` is the 1-based index of the first parameter the predicate may claim;
  returns the fragment and its parameter list.
  """
  @spec predicate(t(), pos_integer()) :: {binary(), [binary()]}
  def predicate(%__MODULE__{expr: expr}, start), do: compile(expr, start)

  defp compile({:tag, value}, index), do: {"tags @> ARRAY[$#{index}]::text[]", [value]}

  defp compile({:type, value}, index), do: {"type = $#{index}", [value]}

  defp compile({kind, branches}, start) when kind in [:any, :all] do
    joiner = if kind == :any, do: " OR ", else: " AND "
    {fragments, params, _next} = compile_list(branches, start)
    {"(" <> Enum.join(fragments, joiner) <> ")", params}
  end

  defp compile({:not, inner}, start) do
    {fragment, params} = compile(inner, start)
    {"(NOT #{fragment})", params}
  end

  defp compile_list([], index), do: {[], [], index}

  defp compile_list([head | rest], index) do
    {fragment, params} = compile(head, index)
    {fragments, tail_params, next} = compile_list(rest, index + length(params))
    {[fragment | fragments], params ++ tail_params, next}
  end

  # walk returns {:ok, walked_expr, counts} | {:error, reason}, threading the
  # node/tag-leaf counters exactly across nested branches.
  defp walk(_expr, depth, _counts) when depth > @max_depth,
    do: {:error, "context query exceeds the #{@max_depth}-level depth bound"}

  defp walk({:tag, value}, _depth, counts) do
    with :ok <- bounded_leaf(value, "tag"),
         {:ok, counts} <- within(counts, :tag_leaves, @max_tag_leaves),
         {:ok, counts} <- within(counts, :nodes, @max_nodes) do
      {:ok, {:tag, value}, counts}
    end
  end

  defp walk({:type, value}, _depth, counts) do
    with :ok <- bounded_leaf(value, "type"),
         {:ok, counts} <- within(counts, :nodes, @max_nodes) do
      {:ok, {:type, value}, counts}
    end
  end

  defp walk({kind, branches}, depth, counts) when kind in [:any, :all] do
    with {:ok, list} <- branch_list(branches),
         {:ok, counts} <- within(counts, :nodes, @max_nodes),
         {:ok, walked, counts} <- walk_list(list, depth + 1, bump(counts, :nodes), []) do
      {:ok, {kind, walked}, counts}
    end
  end

  defp walk({:not, inner}, depth, counts) do
    with {:ok, counts} <- within(counts, :nodes, @max_nodes),
         {:ok, walked, counts} <- walk(inner, depth + 1, bump(counts, :nodes)) do
      {:ok, {:not, walked}, counts}
    end
  end

  defp walk(_other, _depth, _counts), do: {:error, "context query contains an unsupported term"}

  defp walk_list([], _depth, counts, walked), do: {:ok, Enum.reverse(walked), counts}

  defp walk_list([head | rest], depth, counts, walked) do
    case walk(head, depth, counts) do
      {:ok, node, counts} -> walk_list(rest, depth, counts, [node | walked])
      {:error, reason} -> {:error, reason}
    end
  end

  defp branch_list(branches) when is_list(branches) and branches != [], do: {:ok, branches}

  defp branch_list(_branches),
    do: {:error, "context query :any/:all need a nonempty branch list"}

  defp within(counts, key, ceiling) do
    if counts[key] + 1 <= ceiling,
      do: {:ok, Map.update!(counts, key, &(&1 + 1))},
      else: {:error, exceeded(key, ceiling)}
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp exceeded(:nodes, ceiling), do: "context query exceeds the #{ceiling}-node bound"
  defp exceeded(:tag_leaves, ceiling), do: "context query exceeds the #{ceiling}-tag bound"

  defp bounded_leaf(value, kind)
       when is_binary(value) and byte_size(value) in 1..@max_leaf_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      :ok
    else
      {:error, "context query #{kind} must be bounded NUL-free UTF-8"}
    end
  end

  defp bounded_leaf(_value, kind),
    do: {:error, "context query #{kind} must be bounded NUL-free UTF-8"}

  # Soundness: every matching fact carries at least one tag the query names.
  # {:tag, _} anchors; :any needs every branch to anchor (a match satisfies
  # some branch); :all needs one branch to anchor; bare types and negations
  # never anchor. An unanchored query is refused — its check could be matched
  # by a fact carrying none of the writer's locked tags.
  defp anchored?({:tag, _tag}), do: :ok
  defp anchored?({:type, _type}), do: {:error, @unanchored}
  defp anchored?({:not, _inner}), do: {:error, @unanchored}

  defp anchored?({:any, branches}) do
    if Enum.all?(branches, &(anchored?(&1) == :ok)), do: :ok, else: {:error, @unanchored}
  end

  defp anchored?({:all, branches}) do
    if Enum.any?(branches, &(anchored?(&1) == :ok)), do: :ok, else: {:error, @unanchored}
  end

  defp collect_tags({:tag, tag}, acc), do: [tag | acc]

  defp collect_tags({kind, branches}, acc) when kind in [:any, :all],
    do: Enum.reduce(branches, acc, &collect_tags/2)

  defp collect_tags({:not, inner}, acc), do: collect_tags(inner, acc)
  defp collect_tags({:type, _type}, acc), do: acc
end
