defmodule AshOnetime.ExternalState.ProofInventorySourcesTest do
  use ExUnit.Case, async: false
  alias AshOnetime.Test.Repo
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
  Code.require_file("../../../scripts/mutation_inventory.exs", __DIR__)

  setup_all do
    Code.require_file("../../../scripts/mutation_failures.exs", __DIR__)
    Code.require_file("../../../scripts/delivery_comparator_mutations.exs", __DIR__)
    Code.require_file("../../../scripts/delivery_comparator_controls.exs", __DIR__)
    {:__block__, _, nodes} = Code.string_to_quoted!(File.read!("scripts/check_mutations.exs"))
    module_ast = Enum.find(nodes, &match?({:defmodule, _, _}, &1))
    [{module, _binary}] = Code.compile_quoted(module_ast)
    %{manifest: module.manifest()}
  end

  @tag :external_state_inventory_rendered
  test "the rendered enforcing-site inventory equals the mutation manifest", c do
    rendered =
      for hash <- [nil, 2, 4],
          {kind, source} <- [
            install:
              Generator.render(Repo,
                maintenance_role: "inventory_maintainer",
                hash_partitions: hash
              ),
            external_state: Generator.render_external_state_upgrade(Repo, []),
            maintenance:
              Generator.render_maintenance_upgrade(Repo, maintenance_role: "inventory_maintainer"),
            fact_tables: Generator.render_fact_tables(Repo, fact_tables: ["inventory_facts"])
          ],
          do: {"#{kind}/#{hash || "plain"}", source}

    assert :ok =
             AshOnetime.MutationInventory.assert_rendered!(
               c.manifest,
               AshOnetime.MutationInventory.canonical_sources(),
               rendered
             )
  end

  @tag :external_state_inventory_missing_row
  test "rendered inventory keeps markers across interpolated SQL fragments" do
    source = ~S'''
    defmodule InventoryInterpolation do
      def up do
        execute("""
        -- rule:interpolated-check
        CREATE TABLE #{table()} (value integer CHECK (value > 0));
        -- rule:interpolated-refusal
        DO $$ BEGIN RAISE EXCEPTION 'bad %', #{value()}; END $$;
        """)
      end
    end
    '''

    manifest = %{
      "interpolated-check" => %{path: "interpolation"},
      "interpolated-refusal" => %{path: "interpolation"}
    }

    assert :ok =
             AshOnetime.MutationInventory.assert_rendered!(manifest, %{}, [
               {"interpolation", source}
             ])

    unmarked = String.replace(source, "-- rule:interpolated-check", "-- check")

    assert_raise RuntimeError, ~r/unmarked enforcing site.*CHECK/, fn ->
      AshOnetime.MutationInventory.assert_rendered!(manifest, %{}, [{"interpolation", unmarked}])
    end

    nested = ~S|"#{sql("RAISE EXCEPTION 'unmarked'")}"|

    assert_raise RuntimeError, ~r/unmarked enforcing site.*RAISE/, fn ->
      AshOnetime.MutationInventory.assert_rendered!(%{}, %{}, [{"nested interpolation", nested}])
    end
  end

  @tag :external_state_inventory_missing_row
  test "the inventory refuses a missing row inside the multi-rule claim trigger", c do
    sources = %{
      "priv/templates/migrations/external_state/claims.sql" =>
        File.read!("priv/templates/migrations/external_state/claims.sql")
    }

    assert :ok = AshOnetime.MutationInventory.assert_markers!(c.manifest, sources)

    assert_raise RuntimeError, ~r/rule:claim-trigger-identity-id has no manifest row/, fn ->
      AshOnetime.MutationInventory.assert_markers!(
        Map.delete(c.manifest, "claim-trigger-identity-id"),
        sources
      )
    end
  end

  @tag :external_state_inventory_unmarked_enforcer
  test "the inventory refuses an unmarked refusal inside the rendered claim trigger", c do
    source = Generator.render(Repo, maintenance_role: "inventory_maintainer")

    body =
      source
      |> AshOnetime.MutationInventory.routines()
      |> Enum.find(&(&1.name == "ash_onetime_guard_idempotency_update"))
      |> Map.fetch!(:body)

    assert :ok =
             AshOnetime.MutationInventory.assert_rendered!(c.manifest, %{}, [
               {"claim trigger", inspect(body, limit: :infinity, printable_limit: :infinity)}
             ])

    unmarked = String.replace(body, "-- rule:claim-trigger-identity-id", "-- identity refusal")

    assert_raise RuntimeError, ~r/unmarked enforcing site in claim trigger/, fn ->
      AshOnetime.MutationInventory.assert_rendered!(c.manifest, %{}, [
        {"claim trigger", inspect(unmarked, limit: :infinity, printable_limit: :infinity)}
      ])
    end
  end

  @tag :external_state_inventory_unmarked_reraise
  test "the inventory refuses an unmarked re-raise in the rendered roll routine", c do
    body =
      Generator.render(Repo, maintenance_role: "inventory_maintainer")
      |> AshOnetime.MutationInventory.routines()
      |> Enum.find(&(&1.name == "ash_onetime_roll_payload_partitions"))
      |> Map.fetch!(:body)

    assert :ok =
             AshOnetime.MutationInventory.assert_rendered!(c.manifest, %{}, [
               {"roll", inspect(body, limit: :infinity, printable_limit: :infinity)}
             ])

    unmarked = String.replace(body, "-- rule:roll-reraise", "-- exception propagation")

    assert_raise RuntimeError, ~r/unmarked enforcing site in roll/, fn ->
      AshOnetime.MutationInventory.assert_rendered!(c.manifest, %{}, [
        {"roll", inspect(unmarked, limit: :infinity, printable_limit: :infinity)}
      ])
    end
  end
end

for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.ProofInventoryCatalogTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.CatalogInventory
    @moduletag hash_partitions: partitioning
    @moduletag :external_state_inventory_catalog

    test "#{partitioning || "plain"}: every native object equals the rendered-template inventory",
         c do
      assert :ok = CatalogInventory.install_facts!(c)
      expected = CatalogInventory.from_templates!(c)
      actual = CatalogInventory.read(c)
      assert :ok = AshOnetime.MutationInventory.assert_catalog!(expected, actual)

      for kind <- [
            :column_nullability,
            :constraints,
            :triggers,
            :policies,
            :routines,
            :table_acls,
            :column_acls
          ] do
        CatalogInventory.with_drift(c, kind, fn ->
          assert_raise RuntimeError, ~r/live #{kind} differs/, fn ->
            AshOnetime.MutationInventory.assert_catalog!(expected, CatalogInventory.read(c))
          end
        end)

        assert :ok =
                 AshOnetime.MutationInventory.assert_catalog!(expected, CatalogInventory.read(c))
      end

      CatalogInventory.with_drift(c, :journal_acls, fn ->
        assert_raise RuntimeError, ~r/live table_acls differs/, fn ->
          AshOnetime.MutationInventory.assert_catalog!(expected, CatalogInventory.read(c))
        end
      end)
    end
  end
end
