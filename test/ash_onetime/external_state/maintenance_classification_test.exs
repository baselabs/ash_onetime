for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.MaintenanceClassificationTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning

    for {rule, code, message, reason} <- [
          {"maintenance-classify-arguments", "22023", "invalid native argument",
           :invalid_request},
          {"maintenance-classify-timeout", "57014", "native statement cancelled",
           :maintenance_timeout},
          {"maintenance-classify-lock", "55P03", "native lock refused", :lock_unavailable},
          {"maintenance-classify-privilege", "42501", "native privilege refused",
           :maintenance_not_permitted},
          {"maintenance-classify-isolation", "25001", "native isolation refused",
           :unsupported_isolation},
          {"maintenance-classify-blinded", "P0001", "maintenance_blinded: native policy",
           :maintenance_blinded},
          {"maintenance-classify-dependency", "P0001", "untrusted_dependency: native relation",
           :untrusted_dependency},
          {"maintenance-classify-blocked", "P0001", "prune_blocked: native partition",
           :prune_blocked},
          {"maintenance-classify-raised-other", "P0001", "native owner refusal",
           :store_invariant},
          {"maintenance-classify-fallback", "23514", "native check refusal", :store_invariant}
        ] do
      @rule rule
      @code code
      @message message
      @reason reason
      @tag [
        {String.to_atom("enforcement_" <> String.replace(rule, "-", "_") <> "_mutation"), true}
      ]
      test "#{partitioning || "plain"}: #{@rule} retains the native maintenance failure", c do
        identity = routine(c, "ash_onetime_roll_payload_partitions") <> "(integer)"

        [[definition]] =
          SQL.query!(c.owner_repo, "SELECT pg_get_functiondef($1::text::regprocedure)", [identity]).rows

        body =
          String.replace(
            definition,
            "BEGIN\n",
            "BEGIN\n RAISE EXCEPTION #{literal(@message)} USING ERRCODE=#{literal(@code)};\n",
            global: false
          )

        SQL.query!(c.owner_repo, body, [])
        on_exit(fn -> SQL.query!(c.owner_repo, definition, []) end)
        maintenance_target = target(%{c | runtime_repo: c.maintainer_repo})

        assert %Result{
                 status: :failure,
                 reason: @reason,
                 admission_dispatch: :sent,
                 transaction: :rolled_back
               } = Postgres.roll_partitions(maintenance_target, 1)
      end
    end

    @tag :enforcement_maintenance_classify_result_mutation
    test "#{partitioning || "plain"}: a catalog lookup failure retains its store result", c do
      missing = "ao_missing_" <> String.replace(Ecto.UUID.generate(), "-", "")
      maintenance_target = %{target(%{c | runtime_repo: c.maintainer_repo}) | prefix: missing}

      assert [[nil]] =
               SQL.query!(c.maintainer_repo, "SELECT to_regclass($1::text)", [
                 q(missing) <> ".ash_onetime_response_payloads"
               ]).rows

      assert %Result{
               status: :failure,
               reason: :store_invariant,
               admission_dispatch: :sent,
               transaction: :rolled_back
             } = Postgres.roll_partitions(maintenance_target, 1)
    end
  end
end
