Code.require_file("../../../scripts/delivery_comparator_mutations.exs", __DIR__)

defmodule AshOnetime.Delivery.ComparatorMutationsTest do
  alias AshOnetime.Resource.Info, as: OnetimeInfo
  alias AshOnetime.Test.ExitBoundary.Analysis
  alias AshOnetime.Test.ExitBoundary.Comparator
  alias AshOnetime.Test.ExitBoundary.ComparatorMutants
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.Diagnostics
  alias AshOnetime.Test.ExitBoundary.Historical
  alias AshOnetime.Test.ExitBoundary.MutationWitness
  alias AshOnetime.Test.ExitBoundary.Search
  alias AshOnetime.Test.ExitBoundary.Values
  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL
  use AshOnetime.Test.ExitBoundary.ComparatorCase, async: false

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

    for class <- hits |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(),
        do: IO.puts("EXIT_CLASS_HIT=#{class}")

    assert hits == [], "run: a canary crossed the boundary: #{Diagnostics.render(hits)}"
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

          IO.puts(
            "R_NEUTRAL_TUPLE_GREEN" <>
              ": " <> Diagnostics.render(%{mutation: mutation.id, tuple: neutral}, pretty: true)
          )
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
          IO.puts(
            "R_FIRST_DIVERGENCE" <>
              ": " <>
              Diagnostics.render(
                %{
                  mutation: mutation.id,
                  source: if(first, do: Diagnostics.location(first)),
                  raw_canary_hits: hits,
                  difference: Diagnostics.safe(first)
                },
                pretty: true,
                limit: :infinity
              )
          )
        end

        quiet? = hits == []
        assert quiet?, "a raw-canary exit invalidates #{mutation.id}: #{Diagnostics.render(hits)}"

        if first do
          named? = MutationWitness.named?(mutation, first, pair, comparison)
          assert named?, "#{mutation.id}: an earlier or different divergence is not a kill"
          comparator_mutants(mutation, pair, comparison)

          if mutation.extra == :u12 do
            IO.puts(
              "U12_NATIVE_REACHABILITY" <>
                ": " <>
                Diagnostics.render(
                  %{mutation: mutation.id, at: first.at, path: first.path, rule: first.rule},
                  pretty: true
                )
            )
          end
        end

        clear? = comparison.errors == []
        marker = String.upcase(Atom.to_string(mutation.id)) <> "_NAMED_FIRST_DIVERGENCE"
        assert clear?, marker
        :ok
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

          IO.puts(
            "C_SET_NATIVE_COMPARISON" <>
              ": " <>
              Diagnostics.render(
                %{mutation: mutation.id, tuple: label, first: Diagnostics.safe(first)},
                pretty: true,
                limit: :infinity
              )
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

      IO.puts(
        "COMPARATOR_MUTANT" <>
          ": " <>
          Diagnostics.render(
            %{
              rule: rule,
              mutation: mutation.id,
              active: Diagnostics.safe(active_first),
              next: Diagnostics.safe(next),
              remaining: length(disabled.errors)
            },
            pretty: true,
            limit: :infinity
          )
      )

      assert_mutant({rule, mutation.id}, mutation, pair, comparison, active_first, disabled, next)
    end
  end

  defp assert_mutant(
         {:k, :r_iso_k},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [], "R-iso-K must pass with only K's expression disabled"
  end

  defp assert_mutant(
         {:inv, :r_iso_inv},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [],
           "R-iso-inv must pass with only inv's source binding disabled"
  end

  defp assert_mutant(
         {:completion, :r_iso_completion},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [],
           "R-iso-completion must pass with only completion's source binding disabled"
  end

  defp assert_mutant(
         {:completion, :r4},
         mutation,
         pair,
         comparison,
         active_first,
         _disabled,
         next
       ) do
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
  end

  defp assert_mutant(
         {:crypto, :r5},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [], "R5 must pass with only the crypto transfer disabled"
  end

  defp assert_mutant({:crypto, id}, mutation, _pair, _comparison, _active_first, _disabled, next)
       when id in [:r6, :r7] do
    assert next != nil, "#{mutation.id}: a compound crypto mutation must still fail"
  end

  defp assert_mutant(
         {:context, :r_iso_context},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [], "R-iso-context must pass with only CONTEXT disabled"
  end

  defp assert_mutant({:context, :r8}, mutation, pair, _comparison, _active_first, disabled, next) do
    assert next != nil and MutationWitness.named?(mutation, next, pair, disabled),
           "R8's earlier dictionary-read divergence must remain under the CONTEXT mutant"
  end

  defp assert_mutant(
         {:o3, :r_iso_o3},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [],
           "R-iso-O3 must pass with only its duration formula disabled"
  end

  defp assert_mutant(
         {:o2, :r_iso_o2},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [], "R-iso-O2 must pass with only UUID pairing disabled"
  end

  defp assert_mutant(
         {:backend_copy, :r_iso_backend_copy},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [],
           "the backend copy must pass only with O2 backend binding disabled"
  end

  defp assert_mutant(
         {:o4, :r_iso_o4},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [], "R-iso-O4 must pass with only its bind equality disabled"
  end

  defp assert_mutant(
         {:order, :r_iso_order},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [],
           "R-iso-order must pass with only the OPEN call order disabled"
  end

  defp assert_mutant(
         {:order, :r14},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         _disabled,
         next
       ) do
    assert next != nil, "R14's extra call must still fail with its order rule disabled"
  end

  defp assert_mutant({:o3, :r11}, mutation, pair, _comparison, _active_first, disabled, next) do
    assert next != nil and MutationWitness.named?(mutation, next, pair, disabled),
           "R11's earlier dictionary read must remain under the O3 duration mutant"
  end

  defp assert_mutant(
         {:host_multiplicity, :r9},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [], "R9 must pass with only host-call multiplicity disabled"
  end

  defp assert_mutant(
         {:return, :r_iso_return},
         _mutation,
         _pair,
         _comparison,
         _active_first,
         disabled,
         _next
       ) do
    assert disabled.errors == [],
           "R-iso-X3 must pass with only caller-return checks disabled"
  end

  defp assert_mutant({:k, :r2}, _mutation, _pair, _comparison, _active_first, _disabled, next) do
    assert next != nil, "R2's independent multiplicity/order protection must remain"

    refute match?(
             %{at: %{mfa: {AshOnetime.Delivery, :key, 1}}, rule: :permitted_return},
             next
           )
  end

  defp assert_mutant({rule, _}, mutation, pair, _comparison, _active_first, disabled, next) do
    assert next != nil and MutationWitness.named?(mutation, next, pair, disabled),
           "#{mutation.id}: disabling #{rule} changed another rule's named divergence"
  end

  defp with_runtime(%{id: :r_iso_o4, path: path}, _, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_OPERATION") do
      protection =
        OnetimeInfo.protection(AshOnetime.Test.ExitBoundary.Withheld, :issue)

      assert protection.retention <= 2_147_483_647 - 2

      {:ok, operation} =
        AshOnetime.Test.ExitBoundary.Registry.operation(
          AshOnetime.Test.ExitBoundary.Withheld,
          :issue
        )

      source =
        String.replace(source, "COMPARATOR_OPERATION", inspect(operation, limit: :infinity))

      Compiled.with_source(source, path, callback)
    else
      callback.()
    end
  end

  defp with_runtime(%{id: :r_iso_backend_copy, path: path}, context, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_BACKEND_OPERATION") do
      repo = context.repo

      {a, b} = concurrent_backends(repo)

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

      Compiled.with_source(source, path, callback)
    else
      callback.()
    end
  end

  defp with_runtime(%{id: :r28, path: path}, context, callback) do
    source = File.read!(path)

    if String.contains?(source, "COMPARATOR_SOCKET") do
      historical = Historical.capture(context.prefix)

      port =
        Enum.find_value(historical.connections, &connection_socket/1)

      assert is_port(port), "R28 requires the real PostgreSQL connection's socket port"
      previous = :erlang.port_get_data(port)
      assert is_atom(previous), "the socket's native data must name its inet module"

      on_exit(fn -> restore_port_data(port, previous) end)

      # inet_db.lookup_socket reads this module from the port's data. Restore it
      # immediately after the leak, before SQL uses the same live socket again.
      # Both the socket and its original data are bound before tracing.
      source =
        source
        |> String.replace("COMPARATOR_SOCKET_MODULE", inspect(previous))
        |> String.replace("COMPARATOR_SOCKET", List.to_string(:erlang.port_to_list(port)))

      try do
        Compiled.with_source(source, path, callback)
      after
        assert :erlang.port_get_data(port) === previous
      end
    else
      callback.()
    end
  end

  defp with_runtime(_, _, callback), do: callback.()

  defp restore_port_data(port, previous) do
    if :erlang.port_info(port) != :undefined, do: :erlang.port_set_data(port, previous)
  end

  defp concurrent_backends(repo) do
    Repo.checkout(fn ->
      a = backend_pid(repo)
      worker = Task.async(fn -> backend_pid(repo) end)
      {a, Task.await(worker, 30_000)}
    end)
  end

  defp backend_pid(repo) do
    %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp connection_socket({_holder, %{protocol: %{sock: {:gen_tcp, port, _}}}}) when is_port(port),
    do: port

  defp connection_socket({_holder, %{protocol: %{sock: {:gen_tcp, port}}}}) when is_port(port),
    do: port

  defp connection_socket({_holder, %{protocol: %{sock: port}}}) when is_port(port), do: port
  defp connection_socket(_connection), do: nil
end
