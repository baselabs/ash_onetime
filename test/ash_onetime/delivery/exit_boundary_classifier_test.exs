defmodule AshOnetime.Delivery.ExitBoundaryClassifierTest do
  use ExUnit.Case, async: true

  # §2.7.8 rule 3: the classifier is total over the pinned release. Every `bif.tab`
  # declaration and every function of `:erlang` and `:erts_internal` is claimed by a class
  # or listed as pure, so an event through a function missing from the table is red, not
  # silent; and no dependency carries a direct NIF load, which no trace would see.
  #
  # Failures name functions and counts, never terms.

  alias AshOnetime.Test.ExitBoundary.{Classifier, Inventory}

  test "the running release is the one the class table was derived from" do
    assert Inventory.running_release() == Inventory.release()
  end

  test "the inventory has every bif.tab declaration for every supported release" do
    assert length(Inventory.bif_rows("28.5")) == 542
    assert length(Inventory.bif_rows("28.5.0.8")) == 542
    assert length(Inventory.bif_rows("29.1.2")) == 553
  end

  test "an uninventoried runtime fails loudly" do
    assert_raise ArgumentError, ~r/no exit-boundary inventory for OTP/, fn ->
      Inventory.bif_rows("29.1.3")
    end
  end

  test "every bif.tab declaration is claimed by a class or listed as pure" do
    unclaimed =
      for release <- Inventory.releases(),
          %{module: m, function: f, arity: a} <- Inventory.bif_rows(release),
          Classifier.classify_mfa(m, f, a, release) == :unclaimed,
          do: {release, m, f, a}

    assert unclaimed == [],
           "#{length(unclaimed)} bif.tab entries unclaimed: #{inspect(unclaimed)}"
  end

  test "every function of :erlang and :erts_internal is claimed by a class or listed as pure" do
    unclaimed =
      for module <- [:erlang, :erts_internal],
          {f, a} <- module.module_info(:functions),
          Classifier.classify_mfa(module, f, a) == :unclaimed,
          do: {module, f, a}

    assert unclaimed == [], "#{length(unclaimed)} functions unclaimed: #{inspect(unclaimed)}"
  end

  test "the table names only functions that exist at the pinned release" do
    stale =
      for {module, table} <- [
            erlang: Classifier.erlang_table(),
            erts_internal: Classifier.erts_internal_table()
          ],
          functions = MapSet.new(module.module_info(:functions)),
          {{f, a}, _class} <- table,
          not MapSet.member?(functions, {f, a}),
          do: {module, f, a}

    assert stale == [], "#{length(stale)} table entries name no function: #{inspect(stale)}"
  end

  test "every class has a claim and every claim is a class or pure" do
    claimed =
      [Classifier.erlang_table(), Classifier.erts_internal_table(), Classifier.module_table()]
      |> Enum.flat_map(&Map.values/1)
      |> MapSet.new()

    allowed = MapSet.new([:pure | Classifier.classes()])

    assert MapSet.subset?(claimed, allowed)

    missing =
      for class <- Classifier.classes(),
          not MapSet.member?(claimed, class),
          do: class

    assert missing == [], "classes with no claim: #{inspect(missing)}"
  end

  test "an event no class claims classifies as unclaimed" do
    assert Classifier.classify_mfa(:erlang, :no_such_function, 9) == :unclaimed
    assert Classifier.classify_mfa(Enum, :map, 2) == :unclaimed
    assert Classifier.classify({self(), :no_such_tag, :x, :y}) == :unclaimed
  end

  # E18's owned test (scripts/check_mutations.exs, `exit-boundary`): a direct NIF load
  # takes no call trace, so this static check is the class's guard.
  @tag exit_boundary_static: true
  test "no dependency module calls load_nif directly" do
    otp = List.to_string(:code.lib_dir())

    modules =
      for {app, _description, _version} <- Application.loaded_applications(),
          dir = :code.lib_dir(app),
          is_list(dir),
          not String.starts_with?(List.to_string(dir), otp),
          {:ok, modules} <- [:application.get_key(app, :modules)],
          module <- modules,
          do: module

    assert length(modules) > 100

    loading =
      for module <- modules,
          path = :code.which(module),
          is_list(path),
          loads_nif?(path),
          do: module

    assert loading == [], "#{length(loading)} modules load a NIF: #{inspect(loading)}"
  end

  defp loads_nif?(path) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])

    {:beam_file, _module, _exports, _attributes, _info, code} = :beam_disasm.file(path)

    {:erlang, :load_nif, 2} in imports or
      Enum.any?(code, fn {:function, _name, _arity, _entry, instructions} ->
        Enum.any?(instructions, &nif_instruction?/1)
      end)
  end

  # A call to `erlang:load_nif/2` in any form (`call_ext`, `bif`), or the atom passed to
  # an `apply`.
  defp nif_instruction?({:extfunc, :erlang, :load_nif, 2}), do: true
  defp nif_instruction?(:load_nif), do: true

  defp nif_instruction?(instruction) when is_tuple(instruction),
    do: instruction |> Tuple.to_list() |> Enum.any?(&nif_instruction?/1)

  # Walked by hand: a literal in the disassembly can be an improper list.
  defp nif_instruction?([head | tail]), do: nif_instruction?(head) or nif_instruction?(tail)
  defp nif_instruction?(_other), do: false
end
