Code.require_file("../../../scripts/delivery_comparator_mutations.exs", __DIR__)

defmodule AshOnetime.Delivery.ComparatorMutationsTest do
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

  alias AshOnetime.Test.ExitBoundary.{
    Analysis,
    Comparator,
    ComparatorMutants,
    Diagnostics,
    Historical,
    MutationWitness,
    Search,
    Values
  }

  @tag :mutation_hash
  test "mutation hashes equal SHA-256 without a preceding crypto call" do
    source = AshOnetime.DeliveryComparatorHash.inline("input", "digest")
    {hash, _} = Code.eval_string("fn input ->\n" <> source <> "digest\nend")

    inputs =
      [<<>>, "abc", :binary.copy(<<0>>, 55)] ++
        for size <- [8, 16], _ <- 1..16, do: :crypto.strong_rand_bytes(size)

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

    test "#{AshOnetime.DeliveryComparatorMutations.label(mutation)}: named first divergence",
         context do
      mutation =
        Enum.find(AshOnetime.DeliveryComparatorMutations.rows(), &(&1.id == unquote(mutation.id)))

      with_runtime(mutation, context, fn ->
        row = row!(mutation.action, mutation.branch, mutation.fault)
        values = Values.set()

        if neutral = Map.get(mutation, :neutral_value) do
          neutral_pair = observe(context, row, Keyword.fetch!(values, neutral))
          assert Search.hits(neutral_pair.run) == []
          assert Comparator.compare(neutral_pair).errors == [], "the neutral tuple must pass"
          IO.inspect(%{mutation: mutation.id, tuple: neutral}, label: "R_NEUTRAL_TUPLE_GREEN")
        end

        label =
          if Map.has_key?(mutation, :set_pair),
            do:
              Enum.find(
                mutation.set_pair,
                &AshOnetime.DeliveryComparatorMutations.set_active?(mutation, values[&1])
              ),
            else: mutation.value

        pair = observe(context, row, Keyword.fetch!(values, label))
        hits = Search.hits(pair.run)
        comparison = Comparator.compare(pair)
        first = List.first(comparison.errors)

        if first || hits != [] do
          IO.inspect(
            %{
              mutation: mutation.id,
              source: if(first, do: Diagnostics.location(first)),
              raw_canary_hits: hits,
              difference: Diagnostics.safe(first)
            },
            label: "R_FIRST_DIVERGENCE",
            limit: :infinity
          )
        end

        quiet? = hits == []
        assert quiet?, "a raw-canary exit invalidates #{mutation.id}: #{inspect(hits)}"

        if first do
          named? = MutationWitness.named?(mutation, first, pair, comparison)
          assert named?, "#{mutation.id}: an earlier or different divergence is not a kill"
          comparator_mutants(mutation, pair, comparison)

          if mutation.extra == :u12 do
            IO.inspect(%{mutation: mutation.id, at: first.at, path: first.path, rule: first.rule},
              label: "U12_NATIVE_REACHABILITY"
            )
          end
        end

        clear? = comparison.errors == []
        marker = String.upcase(Atom.to_string(mutation.id)) <> "_NAMED_FIRST_DIVERGENCE"
        assert clear?, marker
      end)
    end
  end

  for mutation <- AshOnetime.DeliveryComparatorMutations.set_rows() do
    @tag :c_set
    @tag String.to_atom(Atom.to_string(mutation.id) <> "_c_set")
    test "#{AshOnetime.DeliveryComparatorMutations.label(mutation)}: C-set input pair", context do
      mutation =
        Enum.find(AshOnetime.DeliveryComparatorMutations.rows(), &(&1.id == unquote(mutation.id)))

      row = row!(mutation.action, mutation.branch, mutation.fault)
      values = Values.set()

      expected =
        Enum.map(
          mutation.set_pair,
          &AshOnetime.DeliveryComparatorMutations.set_active?(mutation, values[&1])
        )

      assert Enum.count(expected, & &1) == 1,
             "C-set pair must exercise both sides of its condition"

      observed =
        for label <- mutation.set_pair do
          pair = observe(context, row, Keyword.fetch!(values, label))
          assert Search.hits(pair.run) == [], "C-set requires a quiet raw-canary search"
          comparison = Comparator.compare(pair)
          first = List.first(comparison.errors)

          IO.inspect(%{mutation: mutation.id, tuple: label, first: Diagnostics.safe(first)},
            label: "C_SET_NATIVE_COMPARISON",
            limit: :infinity
          )

          if first do
            assert MutationWitness.named?(mutation, first, pair, comparison),
                   "C-set: an earlier or different divergence is not the conditional witness"
          end

          first != nil
        end

      # Both tuples pass after exact source restoration. With the production
      # mutation installed, exactly the condition's chosen tuple must be red.
      assert observed == [false, false] or observed == expected,
             "C-set mutation must diverge on exactly its selected tuple"

      assert observed == [false, false],
             String.upcase(Atom.to_string(mutation.id)) <> "_C_SET_NAMED_FIRST_DIVERGENCE"
    end
  end

  defp comparator_mutants(mutation, pair, comparison) do
    active_first = hd(comparison.errors)

    for rule <- ComparatorMutants.rules() do
      disabled = ComparatorMutants.compare(pair, rule)
      next = List.first(disabled.errors)

      IO.inspect(
        %{
          rule: rule,
          mutation: mutation.id,
          active: Diagnostics.safe(active_first),
          next: Diagnostics.safe(next),
          remaining: length(disabled.errors)
        },
        label: "COMPARATOR_MUTANT",
        limit: :infinity
      )

      case {rule, mutation.id} do
        {:k, :r_iso_k} ->
          assert disabled.errors == [], "R-iso-K must pass with only K's expression disabled"

        {:inv, :r_iso_inv} ->
          assert disabled.errors == [],
                 "R-iso-inv must pass with only inv's source binding disabled"

        {:completion, :r_iso_completion} ->
          assert disabled.errors == [],
                 "R-iso-completion must pass with only completion's source binding disabled"

        {:completion, :r4} ->
          assert match?(
                   %{
                     at: %{mfa: {:erlang, :put, 2}},
                     rule: :o4,
                     path: [{{:claim_column, :retain_until}, [2, 2, 1, 4, 1, :retain_until]}]
                   },
                   next
                 ),
                 "R4's shifted retention must still fail its own O4 copy at the done put"

          assert next.at.run_index == active_first.at.run_index
          assert MutationWitness.named?(mutation, next, pair, comparison)

        {:crypto, :r5} ->
          assert disabled.errors == [], "R5 must pass with only the crypto transfer disabled"

        {:crypto, id} when id in [:r6, :r7] ->
          assert next != nil, "#{mutation.id}: a compound crypto mutation must still fail"

        {:context, :r_iso_context} ->
          assert disabled.errors == [], "R-iso-context must pass with only CONTEXT disabled"

        {:context, :r8} ->
          assert next != nil and MutationWitness.named?(mutation, next, pair, disabled),
                 "R8's earlier dictionary-read divergence must remain under the CONTEXT mutant"

        {:o3, :r_iso_o3} ->
          assert disabled.errors == [],
                 "R-iso-O3 must pass with only its duration formula disabled"

        {:o2, :r_iso_o2} ->
          assert disabled.errors == [], "R-iso-O2 must pass with only UUID pairing disabled"

        {:backend_copy, :r_iso_backend_copy} ->
          assert disabled.errors == [],
                 "the backend copy must pass only with O2 backend binding disabled"

        {:o4, :r_iso_o4} ->
          assert disabled.errors == [], "R-iso-O4 must pass with only its bind equality disabled"

        {:order, :r_iso_order} ->
          assert disabled.errors == [],
                 "R-iso-order must pass with only the OPEN call order disabled"

        {:order, :r14} ->
          assert next != nil, "R14's extra call must still fail with its order rule disabled"

        {:o3, :r11} ->
          assert next != nil and MutationWitness.named?(mutation, next, pair, disabled),
                 "R11's earlier dictionary read must remain under the O3 duration mutant"

        {:host_multiplicity, :r9} ->
          assert disabled.errors == [], "R9 must pass with only host-call multiplicity disabled"

        {:return, :r_iso_return} ->
          assert disabled.errors == [],
                 "R-iso-X3 must pass with only caller-return checks disabled"

        {:k, :r2} ->
          assert next != nil, "R2's independent multiplicity/order protection must remain"

          refute match?(
                   %{at: %{mfa: {AshOnetime.Delivery, :key, 1}}, rule: :permitted_return},
                   next
                 )

        _ ->
          assert next != nil and MutationWitness.named?(mutation, next, pair, disabled),
                 "#{mutation.id}: disabling #{rule} changed another rule's named divergence"
      end
    end
  end

  defp with_runtime(%{id: :r_iso_o4, path: path}, _, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_OPERATION") do
      protection =
        AshOnetime.Resource.Info.protection(AshOnetime.Test.ExitBoundary.Withheld, :issue)

      assert protection.retention <= 2_147_483_647 - 2

      {:ok, operation} =
        AshOnetime.Test.ExitBoundary.Registry.operation(
          AshOnetime.Test.ExitBoundary.Withheld,
          :issue
        )

      source =
        String.replace(source, "COMPARATOR_OPERATION", inspect(operation, limit: :infinity))

      AshOnetime.Test.ExitBoundary.Compiled.with_source(source, path, callback)
    else
      callback.()
    end
  end

  defp with_runtime(%{id: :r_iso_backend_copy, path: path}, context, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_BACKEND_OPERATION") do
      repo = context.repo

      {a, b} =
        AshOnetime.Test.Repo.checkout(fn ->
          %{rows: [[a]]} = Ecto.Adapters.SQL.query!(repo, "SELECT pg_backend_pid()", [])

          worker =
            Task.async(fn ->
              %{rows: [[b]]} = Ecto.Adapters.SQL.query!(repo, "SELECT pg_backend_pid()", [])
              b
            end)

          {a, Task.await(worker, 30_000)}
        end)

      assert a != b

      {:ok, operation} =
        AshOnetime.Test.ExitBoundary.Registry.operation(
          AshOnetime.Test.ExitBoundary.Withheld,
          :external_issue
        )

      source =
        source
        |> String.replace("COMPARATOR_BACKEND_OPERATION", inspect(operation, limit: :infinity))
        |> String.replace("COMPARATOR_BACKEND_A", Integer.to_string(a))
        |> String.replace("COMPARATOR_BACKEND_B", Integer.to_string(b))

      AshOnetime.Test.ExitBoundary.Compiled.with_source(source, path, callback)
    else
      callback.()
    end
  end

  defp with_runtime(%{id: :r28, path: path}, context, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_SOCKET") do
      historical = Historical.capture(context.prefix)

      port =
        Enum.find_value(historical.connections, fn {_holder, connection} ->
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
      source =
        String.replace(source, "COMPARATOR_SOCKET", List.to_string(:erlang.port_to_list(port)))

      AshOnetime.Test.ExitBoundary.Compiled.with_source(source, path, callback)
    else
      callback.()
    end
  end

  defp with_runtime(_, _, callback), do: callback.()
end
