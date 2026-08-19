defmodule AshOnetime.KeySourceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # ROADMAP H32: key_source.normalize/1 enforces 5 security-relevant invariants on the key
  # (non-empty, <=16 sources, no nesting, unique, valid tags). The iff-property below covers
  # all five through one generator so a regression in any invariant surfaces directly.

  alias AshOnetime.KeySource

  @max_sources 16

  describe "normalize/1 — the 5 invariants" do
    test "a single valid source normalizes to a one-element list" do
      assert {:ok, [{:argument, :key}]} = KeySource.normalize({:argument, :key})
    end

    test "a list of valid sources normalizes verbatim" do
      sources = [{:client, :c}, {:argument, :a}, {:attribute, :attr}]
      assert {:ok, ^sources} = KeySource.normalize(sources)
    end

    test "rejects an empty list" do
      assert {:error, message} = KeySource.normalize([])
      assert message =~ "at least one source"
    end

    test "rejects a list over the 16-source limit" do
      over = for i <- 1..17, do: {:argument, String.to_atom("k#{i}")}
      assert {:error, message} = KeySource.normalize(over)
      assert message =~ "16-source limit"
    end

    test "accepts exactly 16 sources (the boundary)" do
      exact = for i <- 1..16, do: {:argument, String.to_atom("k#{i}")}
      assert {:ok, ^exact} = KeySource.normalize(exact)
    end

    test "rejects a nested composite" do
      nested = [{:argument, :a}, [{:argument, :b}]]
      assert {:error, message} = KeySource.normalize(nested)
      assert message =~ "cannot be nested"
    end

    test "rejects duplicate sources" do
      dup = [{:argument, :a}, {:argument, :a}]
      assert {:error, message} = KeySource.normalize(dup)
      assert message =~ "must be unique"
    end

    test "rejects an unsupported source tag" do
      assert {:error, message} = KeySource.normalize({:unknown, :x})
      assert message =~ "unsupported source"
    end
  end

  property "normalize accepts a source list iff non-empty, <=16, no nesting, unique, all-valid" do
    check all(sources <- list_of(source(), max_length: 20)) do
      expected_ok? =
        sources != [] and length(sources) <= @max_sources and
          not Enum.any?(sources, &is_list/1) and
          Enum.uniq(sources) == sources and
          Enum.all?(sources, &valid_source?/1)

      case KeySource.normalize(sources) do
        {:ok, returned} ->
          assert expected_ok?
          # a successful normalize returns the list verbatim, never reordered/filtered
          assert returned == sources

        {:error, message} ->
          refute expected_ok?
          assert is_binary(message)
      end
    end
  end

  describe "references/1" do
    test "collects client/argument/external/verified as arguments; attribute as attributes; ignores minted" do
      refs =
        KeySource.references([
          {:client, :c},
          {:argument, :a},
          {:external, :e},
          {:verified, :v, SomeModule},
          {:attribute, :attr},
          {:minted, OtherModule}
        ])

      # arguments include client, argument, external, verified names
      assert Enum.sort(refs.arguments) == [:a, :c, :e, :v]
      assert refs.attributes == [:attr]
    end

    property "references returns exactly the argument/attribute names per the source algebra" do
      check all(sources <- uniq_list_of(source(), max_length: 16)) do
        refs = KeySource.references(sources)

        expected_arguments =
          for source <- sources,
              name <- source_argument_names(source),
              do: name

        expected_attributes = for {:attribute, name} <- sources, do: name

        assert Enum.sort(refs.arguments) == Enum.sort(expected_arguments)
        assert Enum.sort(refs.attributes) == Enum.sort(expected_attributes)
      end
    end
  end

  # Generators ----------------------------------------------------------------

  defp source do
    one_of([valid_source(), invalid_source()])
  end

  defp valid_source do
    one_of([
      tuple({constant(:client), atom(:alphanumeric)}),
      tuple({constant(:argument), atom(:alphanumeric)}),
      tuple({constant(:attribute), atom(:alphanumeric)}),
      tuple({constant(:external), atom(:alphanumeric)}),
      tuple({constant(:verified), atom(:alphanumeric), atom(:alphanumeric)}),
      tuple({constant(:minted), atom(:alphanumeric)})
    ])
  end

  defp invalid_source do
    one_of([
      # bad tag
      tuple({constant(:unknown), atom(:alphanumeric)}),
      # non-atom name on a valid tag
      tuple({constant(:argument), string(:alphanumeric, min_length: 1)}),
      # wrong arity on a known tag
      tuple({constant(:client)}),
      # bare atom (not a tuple)
      atom(:alphanumeric),
      # nested list inside (the nesting invariant)
      list_of(atom(:alphanumeric), min_length: 1, max_length: 2)
    ])
  end

  # Mirrors KeySource's own valid_source?/1 exactly so the property oracle is independent of
  # normalize/1's conjunction.
  defp valid_source?({tag, name}) when tag in [:client, :argument, :attribute, :external],
    do: is_atom(name)

  defp valid_source?({:verified, name, module}), do: is_atom(name) and is_atom(module)
  defp valid_source?({:minted, module}), do: is_atom(module)
  defp valid_source?(_), do: false

  defp source_argument_names({:client, name}), do: [name]
  defp source_argument_names({:argument, name}), do: [name]
  defp source_argument_names({:external, name}), do: [name]
  defp source_argument_names({:verified, name, _module}), do: [name]
  defp source_argument_names(_), do: []
end
