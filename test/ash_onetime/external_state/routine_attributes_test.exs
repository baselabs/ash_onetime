for partitioning <- [nil, 2] do
  defmodule Module.concat(AshOnetime.ExternalState.RoutineAttributesTest, "Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {rule, name, definer, setting} <- [
      {"routine-step-definer", "ash_onetime_cleanup_nonce", true, nil},
      {"routine-helper-invoker", "ash_onetime_cleanup_eligible", false, nil},
      {"routine-inside-search-path", "ash_onetime_cleanup_eligible", false, "search_path=pg_catalog, pg_temp"},
      {"outcome-bound-search-path", "ash_onetime_bound_effect_outcome", false, "search_path=pg_catalog, pg_temp"},
      {"outcome-guard-search-path", "ash_onetime_guard_effect_outcome", true, "search_path=pg_catalog, pg_temp"},
      {"visibility-helper-search-path", "ash_onetime_claim_visible", false, "search_path=pg_catalog, pg_temp"},
      {"install-routine-security", "ash_onetime_cleanup_nonce", true, nil},
      {"install-shapes-invoker", "ash_onetime_maintenance_shapes", false, nil},
      {"install-policy-invoker", "ash_onetime_maintenance_policy_error", false, nil},
      {"install-trust-invoker", "ash_onetime_maintenance_trust", false, nil}
    ] do
      @name name
      @definer definer
      @setting setting
      @tag [{String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}]
      test "#{partitioning || "plain"}: #{@name} fixes #{rule}", c do
        assert [[@definer, settings]] = SQL.query!(c.owner_repo, "SELECT prosecdef,proconfig FROM pg_proc WHERE pronamespace=$1::text::regnamespace AND proname=$2", [Postgres.routine_schema(c.schema), @name]).rows
        if @setting, do: assert(@setting in settings)
      end
    end
  end
end
