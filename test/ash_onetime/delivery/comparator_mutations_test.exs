Code.require_file("../../../scripts/delivery_comparator_mutations.exs", __DIR__)

defmodule AshOnetime.Delivery.ComparatorMutationsTest do
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false
  alias AshOnetime.Test.ExitBoundary.{Analysis, Comparator, Diagnostics, Historical, MutationWitness, Search, Values}

  @tag :mutation_hash
  test "mutation hashes equal SHA-256 without a preceding crypto call" do
    source = AshOnetime.DeliveryComparatorHash.inline("input", "digest")
    {hash, _} = Code.eval_string("fn input ->\n" <> source <> "end")
    inputs = [<<>>, "abc", :binary.copy(<<0>>, 55)] ++
      (for size <- [8, 16], _ <- 1..16, do: :crypto.strong_rand_bytes(size))
    for input <- inputs do
      assert hash.(input) === :crypto.hash(:sha256, input)
    end
    refute source =~ ":crypto"
    refute source =~ "fn "
    refute source =~ "Enum."
  end

  @tag :exit_boundary_search
  test "rule 3: no plaintext crosses an undeclared exit", context do
    pair = observe(context, row!(:issue, :execute), Values.set()[:va])
    assert Analysis.unclaimed(pair.run.run.events) == []
    hits = Search.hits(pair.run)
    assert hits == [], "run: a canary crossed the boundary: #{inspect(hits)}"
    assert Comparator.compare(pair).errors == []
  end

  for mutation <- AshOnetime.DeliveryComparatorMutations.rows() do
    @tag mutation.id
    if mutation.extra == :u12 do
      @tag :u12
    end
    test "#{String.upcase(Atom.to_string(mutation.id))}: named first divergence", context do
      mutation = unquote(Macro.escape(mutation))
      prepare_runtime(mutation, context)
      row = row!(mutation.action, mutation.branch, mutation.fault)
      pair = observe(context, row, Keyword.fetch!(Values.set(), mutation.value))
      hits = Search.hits(pair.run)
      comparison = Comparator.compare(pair)
      first = List.first(comparison.errors)
      if first || hits != [] do
        IO.inspect(%{mutation: mutation.id, source: if(first, do: Diagnostics.location(first)),
          raw_canary_hits: hits, difference: Diagnostics.safe(first)},
          label: "R_FIRST_DIVERGENCE", limit: :infinity)
      end
      quiet? = hits == []
      assert quiet?, "a raw-canary exit invalidates #{mutation.id}: #{inspect(hits)}"
      if first do
        named? = MutationWitness.named?(mutation, first, pair, comparison)
        assert named?, "#{mutation.id}: an earlier or different divergence is not a kill"
        if mutation.extra == :u12 do
          IO.inspect(%{mutation: mutation.id, at: first.at, path: first.path, rule: first.rule},
            label: "U12_NATIVE_REACHABILITY")
        end
      end
      clear? = comparison.errors == []
      marker = String.upcase(Atom.to_string(mutation.id)) <> "_NAMED_FIRST_DIVERGENCE"
      assert clear?, marker
    end
  end

  for mutation <- AshOnetime.DeliveryComparatorMutations.parity_rows() do
    @tag :c_set
    @tag String.to_atom(Atom.to_string(mutation.id) <> "_c_set")
    test "#{String.upcase(Atom.to_string(mutation.id))}: C-set uses the opposite length parity", context do
      mutation = unquote(Macro.escape(mutation))
      row = row!(mutation.action, mutation.branch, mutation.fault)
      values = Values.set()
      for label <- [:va, :vd] do
        pair = observe(context, row, Keyword.fetch!(values, label))
        hits = Search.hits(pair.run)
        assert hits == [], "C-set requires a quiet raw-canary search"
        comparison = Comparator.compare(pair)
        first = List.first(comparison.errors)
        IO.inspect(%{mutation: mutation.id, tuple: label, first: Diagnostics.safe(first)},
          label: "C_SET_NATIVE_COMPARISON", limit: :infinity)
        if label == :va do
          neutral? = comparison.errors == []
          assert neutral?, "C-set: Va must pass with the production parity mutation enabled"
        else
          if first do
            assert MutationWitness.named?(mutation, first, pair, comparison),
              "C-set: an earlier or different divergence is not the parity witness"
          end
          clear? = comparison.errors == []
          assert clear?, String.upcase(Atom.to_string(mutation.id)) <> "_C_SET_NAMED_FIRST_DIVERGENCE"
        end
      end
    end
  end

  defp prepare_runtime(%{id: :r28, path: path}, context) do
    source = File.read!(path)
    if String.contains?(source, "COMPARATOR_SOCKET") do
      historical = Historical.capture(context.prefix)
      port = Enum.find_value(historical.connections, fn {_holder, connection} ->
        case connection.protocol.sock do
          {:gen_tcp, port, _} when is_port(port) -> port
          {:gen_tcp, port} when is_port(port) -> port
          port when is_port(port) -> port
          _ -> nil
        end
      end)
      assert is_port(port), "R28 requires the real PostgreSQL connection's socket port"
      previous = :erlang.port_get_data(port)
      on_exit(fn ->
        if :erlang.port_info(port) != :undefined, do: :erlang.port_set_data(port, previous)
      end)
      # Bind the independently captured socket before tracing. No production
      # getter or fixture lookup may become an earlier exit than port_set_data.
      source = String.replace(source, "COMPARATOR_SOCKET", List.to_string(:erlang.port_to_list(port)))
      previous_options = Code.compiler_options(ignore_module_conflict: true)
      try do
        Code.compile_string(source, path)
      after
        Code.compiler_options(previous_options)
      end
    end
  end
  defp prepare_runtime(_, _), do: :ok
end
