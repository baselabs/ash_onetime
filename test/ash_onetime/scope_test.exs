defmodule AshOnetime.ScopeTest do
  @moduledoc """
  Unit coverage for the closed scope algebra (`AshOnetime.Scope`).

  `normalize/1` is the compile-time gate that decides whether a declared scope is admissible;
  `references/1` drives which action inputs a scope binds. Both were only touched indirectly
  before (via `resource_test.exs` and the compile fixtures), so the accept edges — the exact
  16-component limit and the `{:tenant,_}`/`{:argument,_}` forms — and `references/1`'s behavior
  were unproven. Scope-hash collision isolation is inherited from `AshOnetime.Fingerprint`'s
  canonical+SHA-256 injectivity (propertied in `fingerprint_test.exs`) and the claim-identity
  `task5-scope-identity` mutation; this file locks the pure algebra that feeds it.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshOnetime.Scope

  @max_components 16

  describe "normalize/1 accepts every supported, well-formed scope" do
    test "accepts each component form, unchanged and in order" do
      components = [
        {:tenant, AshOnetime.Test.ActionExamples.TenantResolver},
        {:argument, :request_key},
        {:attribute, :account_id},
        {:static, "operation"}
      ]

      assert {:ok, ^components} = Scope.normalize(components)
    end

    test "accepts exactly the #{@max_components}-component limit" do
      exactly_max = for i <- 1..@max_components, do: {:static, "component-#{i}"}
      assert length(exactly_max) == @max_components
      assert {:ok, ^exactly_max} = Scope.normalize(exactly_max)
    end
  end

  describe "normalize/1 fails closed on every malformed scope" do
    test "rejects an empty scope" do
      assert {:error, message} = Scope.normalize([])
      assert message =~ "at least one component"
    end

    @tag :scope_component_limit_mutation
    test "rejects one component over the limit" do
      over = for i <- 1..(@max_components + 1), do: {:static, "component-#{i}"}
      assert {:error, message} = Scope.normalize(over)
      assert message =~ "#{@max_components}-component limit"
    end

    @tag :scope_uniqueness_mutation
    test "rejects duplicate components" do
      assert {:error, message} =
               Scope.normalize([{:static, "x"}, {:attribute, :a}, {:static, "x"}])

      assert message =~ "must be unique"
    end

    test "rejects every unsupported component shape" do
      for bad <- [
            {:static, ""},
            {:static, :not_a_binary},
            {:tenant, "not-a-module"},
            {:argument, "not-an-atom"},
            {:attribute, 123},
            {:unknown, :whatever},
            :not_even_a_tuple,
            "loose string"
          ] do
        assert {:error, message} = Scope.normalize([{:static, "ok"}, bad]),
               "expected #{inspect(bad)} to be rejected"

        assert message =~ "unsupported component"
      end
    end

    test "rejects a non-list scope" do
      for bad <- [:not_a_list, %{}, "string", 42, nil] do
        assert {:error, message} = Scope.normalize(bad)
        assert message =~ "nonempty list"
      end
    end
  end

  property "normalize accepts a list iff it is nonempty, within the limit, unique, and all-valid" do
    check all(components <- list_of(scope_component(), max_length: 20)) do
      expected_ok? =
        components != [] and length(components) <= @max_components and
          Enum.uniq(components) == components and Enum.all?(components, &valid_form?/1)

      case Scope.normalize(components) do
        {:ok, returned} ->
          assert expected_ok?
          # a successful normalize returns the list verbatim, never a reordered/filtered one
          assert returned == components

        {:error, message} ->
          refute expected_ok?
          assert is_binary(message)
      end
    end
  end

  describe "references/1 extracts the argument and attribute names a scope binds" do
    test "collects argument and attribute names; ignores tenant and static" do
      refs =
        Scope.references([
          {:argument, :a1},
          {:attribute, :b1},
          {:tenant, SomeModule},
          {:static, "s"},
          {:argument, :a2},
          {:attribute, :b2}
        ])

      assert Enum.sort(refs.arguments) == [:a1, :a2]
      assert Enum.sort(refs.attributes) == [:b1, :b2]
    end

    test "returns empty lists for a scope with no argument or attribute components" do
      assert %{arguments: [], attributes: []} =
               Scope.references([{:static, "x"}, {:tenant, SomeModule}])
    end

    property "references returns exactly the argument/attribute component names, and nothing else" do
      check all(components <- uniq_list_of(scope_component(), max_length: 16)) do
        refs = Scope.references(components)

        expected_arguments = for {:argument, name} <- components, do: name
        expected_attributes = for {:attribute, name} <- components, do: name

        assert Enum.sort(refs.arguments) == Enum.sort(expected_arguments)
        assert Enum.sort(refs.attributes) == Enum.sort(expected_attributes)
      end
    end
  end

  # Generators ----------------------------------------------------------------

  defp scope_component do
    one_of([valid_component(), invalid_component()])
  end

  defp valid_component do
    one_of([
      tuple({constant(:tenant), member_of([ModuleA, ModuleB, ModuleC])}),
      tuple({constant(:argument), atom(:alphanumeric)}),
      tuple({constant(:attribute), atom(:alphanumeric)}),
      tuple({constant(:static), string(:alphanumeric, min_length: 1, max_length: 8)})
    ])
  end

  defp invalid_component do
    one_of([
      constant({:static, ""}),
      tuple({constant(:tenant), string(:alphanumeric, min_length: 1)}),
      tuple({constant(:argument), string(:alphanumeric, min_length: 1)}),
      tuple({constant(:unknown), atom(:alphanumeric)}),
      atom(:alphanumeric)
    ])
  end

  # Mirrors AshOnetime.Scope.valid_component?/1 exactly, so the property's oracle is independent
  # of normalize/1's own conjunction.
  defp valid_form?({:tenant, module}) when is_atom(module), do: true
  defp valid_form?({:argument, name}) when is_atom(name), do: true
  defp valid_form?({:attribute, name}) when is_atom(name), do: true
  defp valid_form?({:static, bytes}) when is_binary(bytes), do: byte_size(bytes) > 0
  defp valid_form?(_component), do: false
end
