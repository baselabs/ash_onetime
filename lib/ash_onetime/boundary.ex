defmodule AshOnetime.Boundary do
  @moduledoc """
  Conditional append over a context: admit only if nothing relevant changed since read.

  A resource that declares the `context_boundary` section is backed by an append-only
  fact table whose rows carry a monotonic `seq`, a `type`, and a `tags` array. The two
  operations compose into a dynamic consistency boundary:

      {:ok, %{facts: facts, cutoff: cutoff}} =
        AshOnetime.Boundary.read(resource, {:tag, "cart:42"}, tenant: tenant)

      # ... decide on those facts inside the caller's own transaction ...

      AshOnetime.Boundary.append_if(resource, {:tag, "cart:42"}, cutoff, facts_to_append,
        tenant: tenant
      )

  `append_if/5` runs inside the caller's open PostgreSQL transaction. It takes a
  transaction-scoped advisory lock for every tag the query names and every tag the
  appended facts carry — sorted, keyed by tenant and tag — then checks that no fact
  matching the query has a `seq` above `cutoff`, and only then appends. A changed
  context answers `{:error, {:context_changed, max_seq}}`; the caller re-reads and
  decides again.

  Because every matching fact carries a named tag (queries are tag-anchored; see
  `AshOnetime.Boundary.Query`'s validation), writers of one context serialize on those
  tags, their facts commit in `seq` order, and writers with no tag in common never
  block each other.

  Every call requires `:tenant` and fails closed without one; lock keys include it.
  Use `AshOnetime.Boundary.Change` to place the same append on a create action, and see
  the `Context boundaries` guide for worked examples.
  """

  alias AshOnetime.Boundary.Query
  alias AshOnetime.Error
  alias AshOnetime.Resource.Info
  alias AshOnetime.Store.Postgres
  alias Ecto.Adapters.SQL

  @max_tenant_bytes 255
  @max_tags_per_fact 16
  @max_facts_per_append 64
  @max_lock_tags 128
  @default_read_limit 256
  @max_read_limit 1_000

  @read_options ~w(tenant limit prefix)a
  @append_options ~w(tenant prefix)a

  @typedoc "A fact row as read or appended: its seq, type, tags, and insert timestamp."
  @type fact :: %{
          required(:seq) => pos_integer(),
          required(:type) => binary(),
          required(:tags) => [binary()],
          required(:inserted_at) => DateTime.t()
        }

  @typedoc "An input fact to append: `type` plus the `tags` it carries."
  @type fact_input :: %{required(:type) => binary(), required(:tags) => [binary()]}

  @typedoc "The cutoff a read returns: the highest matching seq the caller saw."
  @type cutoff :: non_neg_integer()

  @doc """
  Reads the facts a query matches, newest first, with the context cutoff.

  The cutoff is the highest `seq` among ALL facts the query matches (not just the
  returned page), or `0` for an empty context. Pass it back to `append_if/5`.
  `:tenant` is required. `:limit` bounds the returned page (default #{@default_read_limit},
  ceiling #{@max_read_limit}); the cutoff always spans every matching fact.
  """
  @spec read(Ash.Resource.t(), Query.expr(), keyword()) ::
          {:ok, %{facts: [fact()], cutoff: cutoff()}} | {:error, Error.t()}
  def read(resource, query, options \\ [])

  def read(resource, query, options) when is_atom(resource) and is_list(options) do
    with :ok <- exact_options(options, @read_options),
         {:ok, validated} <- Query.validate(query),
         {:ok, tenant} <- tenant(options),
         {:ok, limit} <- read_limit(options),
         {:ok, target, table} <- resolve(resource, options) do
      read_facts(target, table, tenant, validated, limit)
    else
      {:error, %Error{}} = error -> error
      _other -> invalid_request()
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def read(_resource, _query, _options), do: invalid_request()

  @doc """
  Appends facts only when no fact matching the query changed the context past `cutoff`.

  Runs inside the caller's open PostgreSQL `READ COMMITTED` transaction — it never
  starts one. For every tag the query names and every tag the appended facts carry,
  a transaction-scoped advisory lock is taken in sorted order (keyed by tenant and
  tag), so concurrent writers of one context serialize while writers with no tag in
  common proceed. When a matching fact has committed above the cutoff the append is
  refused with `{:error, {:context_changed, max_seq}}` — re-read and decide again.
  On success returns the appended facts with their assigned `seq` values.

  `:tenant` is required; lock keys include it.
  """
  @spec append_if(Ash.Resource.t(), Query.expr(), cutoff(), [fact_input()], keyword()) ::
          {:ok, [fact()]} | {:error, {:context_changed, pos_integer()}} | {:error, Error.t()}
  def append_if(resource, query, cutoff, facts, options \\ [])

  def append_if(resource, query, cutoff, facts, options)
      when is_atom(resource) and is_list(options) do
    with :ok <- exact_options(options, @append_options),
         {:ok, validated} <- Query.validate(query),
         {:ok, tenant} <- tenant(options),
         {:ok, cutoff} <- bounded_cutoff(cutoff),
         {:ok, normalized} <- normalize_facts(facts),
         :ok <- lock_ceiling(validated, normalized),
         {:ok, target, table} <- resolve(resource, options),
         :ok <- transaction_preconditions(target) do
      append_under_locks(target, table, tenant, validated, cutoff, normalized)
    else
      {:error, %Error{}} = error -> error
      _other -> invalid_request()
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def append_if(_resource, _query, _cutoff, _facts, _options), do: invalid_request()

  # The advisory-lock acquisition order: sorted and deduplicated so every writer
  # takes the same lock set in the same order and overlapping contexts cannot
  # deadlock. Pinned directly by the boundary test suite.
  @doc false
  def sorted_lock_tags(tags), do: tags |> Enum.uniq() |> Enum.sort()

  defp append_under_locks(target, table, tenant, validated, cutoff, normalized) do
    # Nonempty by construction: a validated query is tag-anchored, so it names
    # at least one tag.
    tags = sorted_lock_tags(validated.tags ++ Enum.flat_map(normalized, & &1.tags))

    with :ok <- lock_tags(target, tenant, tags) do
      case context_max_seq(target, table, tenant, validated, cutoff) do
        {:ok, 0} -> insert_facts(target, table, tenant, normalized)
        {:ok, changed_to} -> {:error, {:context_changed, changed_to}}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp read_facts(target, table, tenant, validated, limit) do
    {predicate, predicate_params} = Query.predicate(validated, 2)
    params = [tenant | predicate_params]

    with {:ok, rows} <-
           dispatched(
             target,
             """
             SELECT seq, type, tags, inserted_at
             FROM #{relation(target, table)}
             WHERE tenant = $1 AND #{predicate}
             ORDER BY seq DESC
             LIMIT $#{length(params) + 1}
             """,
             params ++ [limit]
           ),
         {:ok, [[cutoff]]} when is_integer(cutoff) and cutoff >= 0 <-
           dispatched(
             target,
             """
             SELECT coalesce(max(seq), 0)
             FROM #{relation(target, table)}
             WHERE tenant = $1 AND #{predicate}
             """,
             params
           ) do
      facts = Enum.map(rows, &decode_fact/1)

      # An empty page is a valid empty context; only a malformed row is not.
      if Enum.all?(facts, &is_map/1) do
        {:ok, %{facts: facts, cutoff: cutoff}}
      else
        store_invariant()
      end
    else
      _other -> store_invariant()
    end
  end

  defp context_max_seq(target, table, tenant, validated, cutoff) do
    {predicate, predicate_params} = Query.predicate(validated, 3)

    case dispatched(
           target,
           """
           SELECT coalesce(max(seq), 0)
           FROM #{relation(target, table)}
           WHERE tenant = $1 AND seq > $2 AND #{predicate}
           """,
           [tenant, cutoff | predicate_params]
         ) do
      {:ok, [[max_seq]]} when is_integer(max_seq) and max_seq >= 0 -> {:ok, max_seq}
      _other -> store_invariant()
    end
  end

  defp insert_facts(target, table, tenant, normalized) do
    {values, params} = insert_values(tenant, normalized)

    case dispatched(
           target,
           """
           INSERT INTO #{relation(target, table)} (tenant, type, tags)
           VALUES #{values}
           RETURNING seq, type, tags, inserted_at
           """,
           params
         ) do
      {:ok, rows} when length(rows) == length(normalized) ->
        facts = Enum.map(rows, &decode_fact/1)

        if Enum.all?(facts, &is_map/1) do
          {:ok, facts}
        else
          store_invariant()
        end

      _other ->
        store_invariant()
    end
  end

  # Every row reuses $1 for the tenant; each row then claims the next two
  # parameters for its type and tags.
  defp insert_values(tenant, normalized) do
    {fragments, params, _next} =
      Enum.reduce(normalized, {[], [], 2}, fn %{type: type, tags: tags}, {frags, acc, index} ->
        tag_index = index + 1
        row = "($1, $#{index}, $#{tag_index}::text[])"
        {[row | frags], acc ++ [type, tags], tag_index + 1}
      end)

    {Enum.join(Enum.reverse(fragments), ", "), [tenant | params]}
  end

  defp lock_tags(target, tenant, tags) do
    Enum.reduce_while(tags, :ok, fn tag, :ok ->
      case dispatched(
             target,
             "SELECT pg_advisory_xact_lock(hashtext($1::text), hashtext($2::text))",
             [
               tenant,
               tag
             ]
           ) do
        {:ok, _rows} -> {:cont, :ok}
        _other -> {:halt, store_invariant()}
      end
    end)
  end

  defp transaction_preconditions(target) do
    if target.repo_module.in_transaction?() do
      case dispatched(target, "SHOW transaction_isolation", []) do
        {:ok, [["read committed"]]} -> :ok
        {:ok, _other} -> unsupported_isolation()
        _other -> store_invariant()
      end
    else
      not_in_transaction()
    end
  end

  defp exact_options(options, allowed) do
    keys = Keyword.keys(options)

    if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in allowed)) do
      :ok
    else
      invalid_request()
    end
  end

  defp tenant(options) do
    case Keyword.get(options, :tenant) do
      tenant when is_binary(tenant) ->
        if byte_size(tenant) in 1..@max_tenant_bytes and String.valid?(tenant) and
             not String.contains?(tenant, <<0>>) do
          {:ok, tenant}
        else
          invalid_request()
        end

      _other ->
        invalid_request()
    end
  end

  defp read_limit(options) do
    case Keyword.get(options, :limit, @default_read_limit) do
      limit when is_integer(limit) and limit in 1..@max_read_limit -> {:ok, limit}
      _other -> invalid_request()
    end
  end

  defp bounded_cutoff(cutoff) when is_integer(cutoff) and cutoff >= 0, do: {:ok, cutoff}
  defp bounded_cutoff(_cutoff), do: invalid_request()

  defp normalize_facts(facts) when is_list(facts) and facts != [] do
    if length(facts) <= @max_facts_per_append and Enum.all?(facts, &valid_fact?/1) do
      {:ok, Enum.map(facts, &normalize_fact/1)}
    else
      invalid_request()
    end
  end

  defp normalize_facts(_facts), do: invalid_request()

  defp valid_fact?(fact) do
    case normalize_fact(fact) do
      %{type: type, tags: tags} ->
        is_binary(type) and byte_size(type) in 1..255 and String.valid?(type) and
          not String.contains?(type, <<0>>) and
          length(tags) in 1..@max_tags_per_fact and Enum.all?(tags, &bounded_tag?/1)

      :invalid ->
        false
    end
  end

  # Facts arrive as maps with atom keys or (after Ash :map argument normalization)
  # string keys.
  defp normalize_fact(%{type: type, tags: tags}), do: %{type: type, tags: tags}

  defp normalize_fact(%{"type" => type, "tags" => tags}), do: %{type: type, tags: tags}

  defp normalize_fact(fact) when is_list(fact) do
    if Keyword.keyword?(fact) do
      %{type: Keyword.get(fact, :type), tags: Keyword.get(fact, :tags)}
    else
      :invalid
    end
  end

  defp normalize_fact(_other), do: :invalid

  defp bounded_tag?(tag) do
    is_binary(tag) and byte_size(tag) in 1..255 and String.valid?(tag) and
      not String.contains?(tag, <<0>>)
  end

  defp lock_ceiling(validated, normalized) do
    distinct =
      (validated.tags ++ Enum.flat_map(normalized, & &1.tags))
      |> Enum.uniq()
      |> length()

    if distinct <= @max_lock_tags, do: :ok, else: invalid_request()
  end

  defp resolve(resource, options) do
    with %{fact_table: table} when is_binary(table) <- Info.context_boundary(resource),
         {:ok, repo, prefix} <- data_layer_target(resource, options) do
      {:ok, Postgres.for_repo(repo, prefix), table}
    else
      _other -> invalid_request()
    end
  rescue
    _exception -> invalid_request()
  end

  defp data_layer_target(resource, options) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)
    prefix = options[:prefix] || AshPostgres.DataLayer.Info.schema(resource)

    if is_nil(prefix) or (is_binary(prefix) and byte_size(prefix) in 1..63) do
      {:ok, repo, prefix}
    else
      {:error, :invalid_prefix}
    end
  end

  defp dispatched(target, sql, params) do
    case SQL.query(target.dynamic_repo, sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows}
      {:ok, _other} -> {:error, :unexpected_result}
      {:error, _error} -> {:error, :query_failed}
    end
  end

  defp decode_fact([seq, type, tags, %DateTime{} = inserted_at])
       when is_integer(seq) and is_binary(type) and is_list(tags),
       do: %{seq: seq, type: type, tags: tags, inserted_at: inserted_at}

  defp decode_fact(_other), do: :invalid

  defp relation(%Postgres.Target{prefix: nil}, name), do: quote_identifier(name)

  defp relation(%Postgres.Target{prefix: prefix}, name),
    do: quote_identifier(prefix) <> "." <> quote_identifier(name)

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp invalid_request,
    do: {:error, Error.new(:invalid_request, "context boundary request is invalid")}

  defp not_in_transaction,
    do: {:error, Error.new(:not_in_transaction, "append_if requires the caller's transaction")}

  defp unsupported_isolation,
    do:
      {:error,
       Error.new(:unsupported_isolation, "context boundary requires READ COMMITTED isolation")}

  defp store_invariant,
    do: {:error, Error.new(:store_invariant, "context boundary fact store failed")}

  defp unavailable,
    do: {:error, Error.new(:boundary_unavailable, "context boundary is unavailable")}
end
