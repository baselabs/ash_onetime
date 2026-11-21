Code.require_file("mutation_failures.exs", __DIR__)

defmodule AshOnetime.MutationCheck do
  @moduledoc false

  @mutations %{
    "inventory-unmarked-enforcer" => %{
      path: "scripts/mutation_inventory.exs",
      original: "sites = Regex.scan(@enforcer, sql, return: :index)",
      mutated: "sites = []",
      test: "test/ash_onetime/external_state/proof_inventory_test.exs",
      tag: "external_state_inventory_unmarked_enforcer",
      test_name: "the inventory refuses an unmarked refusal inside the rendered claim trigger",
      assertion: "assert_raise",
      assertion_line: 112
    },
    "inventory-missing-row" => %{
      path: "scripts/mutation_inventory.exs",
      original: "[\"rule:\#{site.id} has no manifest row at \#{site.path}:\#{site.line}\"]",
      mutated: "[]",
      test: "test/ash_onetime/external_state/proof_inventory_test.exs",
      tag: "external_state_inventory_missing_row",
      test_name: "the inventory refuses a missing row inside the multi-rule claim trigger",
      assertion: "Expected exception RuntimeError but nothing was raised"
    },
    "inventory-catalog-equality" => %{
      path: "scripts/mutation_inventory.exs",
      original: "if Map.fetch!(actual, kind) == values,",
      mutated: "if Map.fetch!(actual, kind) == values or true,",
      test: "test/ash_onetime/external_state/proof_inventory_test.exs",
      tag: "external_state_inventory_catalog",
      test_name: "plain: every native object equals the rendered-template inventory",
      assertion: "Expected exception RuntimeError but nothing was raised"
    },
    "outcomes-primary-key" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: ", PRIMARY KEY (@key_columns@claim_id, attempt)",
      mutated: "",
      test: "test/ash_onetime/external_state/outcome_constraints_test.exs",
      tag: "external_state_outcomes_primary_key_mutation",
      test_name: "plain: the outcome primary key refuses a second row for an attempt",
      assertion: "assert",
      assertion_line: 32,
      required_failures: [
        %{
          test_name: "plain: the outcome primary key refuses a second row for an attempt",
          assertion: "assert",
          assertion_line: 32
        },
        %{
          test_name: "2: the outcome primary key refuses a second row for an attempt",
          assertion: "assert",
          assertion_line: 32
        }
      ]
    },
    "outcomes-check-outcome" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "CHECK (outcome IN ('held','absent_proven'))",
      mutated: "",
      test: "test/ash_onetime/external_state/outcome_constraints_test.exs",
      tag: "external_state_outcomes_check_outcome_mutation",
      test_name: "plain: the outcome CHECK refuses an unknown value",
      assertion: "assert",
      assertion_line: 21,
      required_failures: [
        %{
          test_name: "plain: the outcome CHECK refuses an unknown value",
          assertion: "assert",
          assertion_line: 21
        },
        %{
          test_name: "2: the outcome CHECK refuses an unknown value",
          assertion: "assert",
          assertion_line: 21
        }
      ]
    },
    "outcomes-check-attempt" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "CHECK (attempt >= 1)",
      mutated: "",
      test: "test/ash_onetime/external_state/outcome_constraints_test.exs",
      tag: "external_state_outcomes_check_attempt_mutation",
      test_name: "plain: the outcome CHECK refuses attempt zero",
      assertion: "assert",
      assertion_line: 13,
      required_failures: [
        %{
          test_name: "plain: the outcome CHECK refuses attempt zero",
          assertion: "assert",
          assertion_line: 13
        },
        %{
          test_name: "2: the outcome CHECK refuses attempt zero",
          assertion: "assert",
          assertion_line: 13
        }
      ]
    },
    "rollback-lock-install" => %{
      path: "priv/templates/migrations/install.exs",
      original:
        "      -- rule:rollback-lock-install\n      LOCK TABLE \#{q(\"ash_onetime_idempotency_claims\")}, \#{q(\"ash_onetime_effect_outcomes\")} IN ACCESS EXCLUSIVE MODE;",
      mutated: "      -- rule:rollback-lock-install\n      NULL;",
      test: "test/ash_onetime/external_state/rollback_lock_test.exs",
      tag: "external_state_rollback_lock_mutation",
      test_name: "plain: install rollback excludes reservations after its refusal count",
      assertion: "assert",
      assertion_line: 59,
      required_failures: [
        %{
          test_name: "plain: install rollback excludes reservations after its refusal count",
          assertion: "assert",
          assertion_line: 59
        },
        %{
          test_name: "2: install rollback excludes reservations after its refusal count",
          assertion: "assert",
          assertion_line: 59
        }
      ]
    },
    "rollback-lock-external-state" => %{
      path: "priv/templates/migrations/external_state.exs",
      original:
        "      -- rule:rollback-lock-external-state\n      LOCK TABLE \#{q(@claims)}, \#{q(\"ash_onetime_effect_outcomes\")} IN ACCESS EXCLUSIVE MODE;",
      mutated: "      -- rule:rollback-lock-external-state\n      NULL;",
      test: "test/ash_onetime/external_state/rollback_lock_test.exs",
      tag: "external_state_rollback_lock_mutation",
      test_name: "plain: external_state rollback excludes reservations after its refusal count",
      assertion: "assert",
      assertion_line: 59,
      required_failures: [
        %{
          test_name:
            "plain: external_state rollback excludes reservations after its refusal count",
          assertion: "assert",
          assertion_line: 59
        },
        %{
          test_name: "2: external_state rollback excludes reservations after its refusal count",
          assertion: "assert",
          assertion_line: 59
        }
      ]
    },
    "rollback-lock-maintenance" => %{
      path: "priv/templates/migrations/maintenance.exs",
      original:
        "      -- rule:rollback-lock-maintenance\n      LOCK TABLE \#{q(\"ash_onetime_idempotency_claims\")}, \#{q(\"ash_onetime_effect_outcomes\")} IN ACCESS EXCLUSIVE MODE;",
      mutated: "      -- rule:rollback-lock-maintenance\n      NULL;",
      test: "test/ash_onetime/external_state/rollback_lock_test.exs",
      tag: "external_state_rollback_lock_mutation",
      test_name: "plain: maintenance rollback excludes reservations after its refusal count",
      assertion: "assert",
      assertion_line: 59,
      required_failures: [
        %{
          test_name: "plain: maintenance rollback excludes reservations after its refusal count",
          assertion: "assert",
          assertion_line: 59
        },
        %{
          test_name: "2: maintenance rollback excludes reservations after its refusal count",
          assertion: "assert",
          assertion_line: 59
        }
      ]
    },
    "roll-relocation" => %{
      tag: "roll_relocation_mutation",
      path: "priv/templates/migrations/maintenance/roll.sql",
      original:
        "WITH moved AS (DELETE FROM %s WHERE partition_date >= $1 AND partition_date < $2 RETURNING *) INSERT INTO %I.%I SELECT * FROM moved",
      test: "test/ash_onetime/store/maintenance_test.exs",
      assertion_line: 2915,
      test_name: "roll recovers past and forward DEFAULT months atomically and restores FORCE",
      assertion: "assert",
      mutated:
        "WITH moved AS (DELETE FROM %s WHERE partition_date >= $1 AND partition_date < $2 RETURNING *) SELECT count(*) FROM moved /* %I.%I */"
    },
    "cleanup-complete-only" => %{
      path: "priv/templates/migrations/maintenance/cleanup_idempotency.sql",
      original: "    WHERE state='complete' AND hold_reference IS NULL",
      mutated: "    WHERE hold_reference IS NULL",
      test: "test/ash_onetime/store/cleanup_test.exs",
      tag: "external_processing_cleanup_mutation",
      test_name:
        "expired processing recovery points are neither cleanup nor direct-delete eligible",
      assertion: "assert",
      assertion_line: 161,
      required_failures: [
        %{
          test_name:
            "expired processing recovery points are neither cleanup nor direct-delete eligible",
          assertion: "assert",
          assertion_line: 161
        }
      ]
    },
    "expired-after-fingerprint" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "    # rule:expired-after-fingerprint\n    with {:ok, disposition} <-\n           validate_collision(result, state.request, state.target, expected_transaction(mode)),",
      mutated:
        "    # rule:expired-after-fingerprint\n    with {:ok, disposition} <-\n           if(result.claim.response_expired_at, do: {:error, Error.new(:response_expired, \"stored response has expired\")}, else: validate_collision(result, state.request, state.target, expected_transaction(mode))),",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name:
        "plain: an expired replay compares its fingerprint before returning response_expired",
      assertion: "assert",
      assertion_line: 38,
      required_failures: [
        %{
          test_name:
            "plain: an expired replay compares its fingerprint before returning response_expired",
          assertion: "assert",
          assertion_line: 38
        },
        %{
          test_name:
            "2: an expired replay compares its fingerprint before returning response_expired",
          assertion: "assert",
          assertion_line: 38
        }
      ]
    },
    "load-after-claim-lock" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "    if strategy == :idempotency do\n      lock_sql = \"\"\"\n      SELECT 1 FROM \#{relation(target, table)} claims\n      WHERE claims.logical_partition=$1 AND claims.operation_hash=$2 AND claims.scope_hash=$3 AND claims.key_hash=$4\#{id_predicate}\n      FOR \#{lock_mode} OF claims\n      \"\"\"\n\n      case dispatched_query(target, lock_sql, parameters) do\n        {:ok, %{num_rows: 1}} -> select_claim_result(target, strategy, sql, parameters)\n        {:ok, %{num_rows: 0}} -> {:error, :missing}\n        {:ok, _result} -> {:error, Result.failure(:store_invariant, :sent, :open)}\n        {:error, %Result{} = result} -> {:error, result}\n      end\n    else\n      # rule:nonce-select-lock\n      select_claim_result(target, strategy, sql <> \" FOR \#{lock_mode} OF claims\", parameters)\n    end",
      mutated:
        "    case select_claim_result(target, strategy, sql <> \" FOR \#{lock_mode} OF claims\", parameters) do\n      {:ok, %Claim{state: :complete, response_expired_at: nil, response_payload: nil}}\n      when strategy == :idempotency ->\n        select_claim_result(target, strategy, sql <> \" FOR \#{lock_mode} OF claims\", parameters)\n\n      result ->\n        result\n    end",
      test: "test/ash_onetime/external_state/load_snapshot_test.exs",
      tag: "external_state_load_after_claim_lock_mutation",
      test_name: "plain: lock wait, outcome during the wait",
      assertion: "assert",
      assertion_line: 183
    },
    "upgrade-legacy-keys" => %{
      path: "priv/templates/migrations/external_state.exs",
      original:
        "          IF historical_key THEN\n            SELECT conname INTO STRICT primary_constraint FROM pg_constraint WHERE conrelid=target.oid AND contype='p';\n            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',target.oid::regclass,primary_constraint);\n            EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s',target.oid::regclass,primary_constraint,manifest->>(target.relname || '_primary_ddl'));\n          END IF;",
      mutated: "          NULL;",
      test: "test/ash_onetime/external_state/upgrade_test.exs",
      tag: "external_state_upgrade_mutation",
      test_name:
        "2: historical logical-partition keys are authenticated and rekeyed before the outcome FK",
      assertion: "assert",
      assertion_line: 17,
      required_failures: [
        %{
          test_name:
            "2: historical logical-partition keys are authenticated and rekeyed before the outcome FK",
          assertion: "assert",
          assertion_line: 17
        },
        %{
          test_name:
            "4: historical logical-partition keys are authenticated and rekeyed before the outcome FK",
          assertion: "assert",
          assertion_line: 17
        }
      ]
    },
    "upgrade-shape-authentication" => %{
      path: "priv/templates/migrations/external_state.exs",
      original:
        "        IF expected_shape IS NULL OR historical_shape IS NULL\n          OR (actual_shape-'constraints' IS DISTINCT FROM expected_shape-'constraints'\n            AND actual_shape-'constraints' IS DISTINCT FROM historical_shape-'constraints')\n          -- rule:maintenance-upgrade-constraint-count\n          OR jsonb_array_length(actual_shape->'constraints')<>jsonb_array_length(expected_shape->'constraints')\n          OR EXISTS (SELECT 1 FROM jsonb_array_elements(actual_shape->'constraints') x\n            WHERE NOT (expected_shape->'constraints') @> jsonb_build_array(x)\n              AND NOT (historical_shape->'constraints') @> jsonb_build_array(x))\n          -- rule:maintenance-upgrade-constraint-coverage\n          OR EXISTS (SELECT 1 FROM jsonb_array_elements(expected_shape->'constraints') e\n            WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(actual_shape->'constraints') x\n              WHERE x=e OR ((historical_shape->'constraints') @> jsonb_build_array(x)\n                AND (x-'expression'=e-'expression' OR (x->>'type'='p' AND e->>'type'='p'))))) THEN\n          RAISE EXCEPTION 'untrusted_dependency: upgrade relation shape %',target.relname USING DETAIL=jsonb_build_object('actual',actual_shape,'expected',expected_shape,'historical',historical_shape)::text;\n        END IF;",
      mutated: "        NULL;",
      test: "test/ash_onetime/external_state/upgrade_test.exs",
      tag: "external_state_upgrade_mutation",
      test_name: "plain: an extra historical CHECK is refused before adding external state",
      assertion: "assert",
      assertion_line: 78,
      required_failures: [
        %{
          test_name: "plain: an extra historical CHECK is refused before adding external state",
          assertion: "assert",
          assertion_line: 78
        },
        %{
          test_name: "2: an extra historical CHECK is refused before adding external state",
          assertion: "assert",
          assertion_line: 78
        },
        %{
          test_name: "4: an extra historical CHECK is refused before adding external state",
          assertion: "assert",
          assertion_line: 78
        }
      ]
    },
    "rollback-refusal-external-state" => %{
      path: "priv/templates/migrations/external_state.exs",
      original:
        "      IF EXISTS (SELECT 1 FROM \#{q(@claims)} WHERE state='processing' AND NOT effect_local) THEN\n        RAISE EXCEPTION 'unresolved external claims prevent rollback' USING ERRCODE='23514';\n      END IF;",
      mutated: "      NULL;",
      test: "test/ash_onetime/external_state/upgrade_test.exs",
      tag: "external_state_upgrade_mutation",
      test_name:
        "plain: external-state rollback refuses unresolved claims before removing protection",
      assertion: "assert",
      assertion_line: 152,
      required_failures: [
        %{
          test_name:
            "plain: external-state rollback refuses unresolved claims before removing protection",
          assertion: "assert",
          assertion_line: 152
        },
        %{
          test_name:
            "2: external-state rollback refuses unresolved claims before removing protection",
          assertion: "assert",
          assertion_line: 152
        },
        %{
          test_name:
            "4: external-state rollback refuses unresolved claims before removing protection",
          assertion: "assert",
          assertion_line: 152
        }
      ]
    },
    "rollback-refusal-expired" => %{
      path: "priv/templates/migrations/external_state.exs",
      original:
        "      IF EXISTS (SELECT 1 FROM \#{q(@claims)} WHERE response_expired_at IS NOT NULL) THEN\n        RAISE EXCEPTION 'expired responses prevent rollback' USING ERRCODE='23514';\n      END IF;",
      mutated: "      NULL;",
      test: "test/ash_onetime/external_state/upgrade_test.exs",
      tag: "external_state_upgrade_mutation",
      test_name: "plain: external-state rollback refuses expired responses before the old CHECK",
      assertion: "assert",
      assertion_line: 202,
      required_failures: [
        %{
          test_name:
            "plain: external-state rollback refuses expired responses before the old CHECK",
          assertion: "assert",
          assertion_line: 202
        },
        %{
          test_name: "2: external-state rollback refuses expired responses before the old CHECK",
          assertion: "assert",
          assertion_line: 202
        },
        %{
          test_name: "4: external-state rollback refuses expired responses before the old CHECK",
          assertion: "assert",
          assertion_line: 202
        }
      ]
    },
    "rollback-refusal-maintenance" => %{
      path: "priv/templates/migrations/maintenance.exs",
      original:
        "      IF EXISTS (SELECT 1 FROM \#{q(\"ash_onetime_idempotency_claims\")} WHERE state='processing' AND NOT effect_local) THEN\n        RAISE EXCEPTION 'unresolved external claims prevent rollback' USING ERRCODE='23514';\n      END IF;",
      mutated: "      NULL;",
      test: "test/ash_onetime/external_state/upgrade_test.exs",
      tag: "external_state_upgrade_mutation",
      test_name:
        "plain: maintenance rollback refuses unresolved claims before restoring routines",
      assertion: "assert",
      assertion_line: 169,
      required_failures: [
        %{
          test_name:
            "plain: maintenance rollback refuses unresolved claims before restoring routines",
          assertion: "assert",
          assertion_line: 169
        },
        %{
          test_name:
            "2: maintenance rollback refuses unresolved claims before restoring routines",
          assertion: "assert",
          assertion_line: 169
        },
        %{
          test_name:
            "4: maintenance rollback refuses unresolved claims before restoring routines",
          assertion: "assert",
          assertion_line: 169
        }
      ]
    },
    "generator-order" => %{
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original:
        "          {\"operation_hold\", \"operation-hold\"},\n          {\"external_state\", \"external-state\"}",
      mutated: "          {\"operation_hold\", \"operation-hold\"}",
      test: "test/ash_onetime/external_state/upgrade_rollback_test.exs",
      tag: "external_state_upgrade_generator_mutation",
      test_name: "maintenance requires the external-state migration as well as operation hold",
      assertion: "assert",
      assertion_line: 99,
      required_failures: [
        %{
          test_name:
            "maintenance requires the external-state migration as well as operation hold",
          assertion: "assert",
          assertion_line: 99
        }
      ]
    },
    "reference-graph-complete" => %{
      path: "priv/templates/migrations/maintenance/reference.sql",
      original: "  capture_after_graph boolean := true;",
      mutated: "  capture_after_graph boolean := false;",
      test: "test/ash_onetime/external_state/shape_graph_test.exs",
      tag: "external_state_shape_graph_mutation",
      test_name: "plain: trust reconstructs the complete FK graph on an untouched install",
      assertion: "assert",
      assertion_line: 18,
      required_failures: [
        %{
          test_name: "plain: trust reconstructs the complete FK graph on an untouched install",
          assertion: "assert",
          assertion_line: 18
        },
        %{
          test_name: "2: trust reconstructs the complete FK graph on an untouched install",
          assertion: "assert",
          assertion_line: 18
        },
        %{
          test_name: "4: trust reconstructs the complete FK graph on an untouched install",
          assertion: "assert",
          assertion_line: 18
        }
      ]
    },
    "shape-ri-normalization" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original:
        "CASE WHEN t.tgisinternal AND p.proname LIKE 'RI_FKey_%' AND p.pronamespace='pg_catalog'::regnamespace THEN p.proname ELSE t.tgname END",
      mutated: "t.tgname",
      test: "test/ash_onetime/external_state/shape_graph_test.exs",
      tag: "external_state_shape_graph_mutation",
      test_name: "plain: trust reconstructs the complete FK graph on an untouched install",
      assertion: "assert",
      assertion_line: 18,
      required_failures: [
        %{
          test_name: "plain: trust reconstructs the complete FK graph on an untouched install",
          assertion: "assert",
          assertion_line: 18
        },
        %{
          test_name: "2: trust reconstructs the complete FK graph on an untouched install",
          assertion: "assert",
          assertion_line: 18
        },
        %{
          test_name: "4: trust reconstructs the complete FK graph on an untouched install",
          assertion: "assert",
          assertion_line: 18
        }
      ]
    },
    "operation-hold-do-block" => %{
      path: "priv/templates/migrations/operation_hold.exs",
      original:
        "      \#{install_previous_functions()}\n      ALTER TABLE \#{q(@claims)} DROP CONSTRAINT \#{qi(@check)}, DROP COLUMN hold_reference;\n    END\n    $down$\n    \"\"\")",
      mutated:
        "    END\n    $down$\n    \"\"\")\n    execute(\"\"\"\n    DO $restore$\n    BEGIN\n      \#{install_previous_functions()}\n      ALTER TABLE \#{q(@claims)} DROP CONSTRAINT \#{qi(@check)}, DROP COLUMN hold_reference;\n    END\n    $restore$\n    \"\"\")",
      test: "test/ash_onetime/external_state/upgrade_rollback_test.exs",
      tag: "operation_hold_atomic_mutation",
      test_name: "operation-hold rollback restores guards inside the locked refusal block",
      assertion: "assert",
      assertion_line: 144,
      required_failures: [
        %{
          test_name: "operation-hold rollback restores guards inside the locked refusal block",
          assertion: "assert",
          assertion_line: 144
        }
      ]
    },
    "delete-guard-inline-eligibility" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original:
        "  -- rule:delete-guard-inline-eligibility\n  IF NOT (transaction_timestamp() > OLD.retain_until) THEN",
      mutated:
        "  -- rule:delete-guard-inline-eligibility\n  IF NOT @routines@.ash_onetime_cleanup_eligible(OLD.retain_until::timestamptz) THEN",
      test: "test/ash_onetime/external_state/delete_guard_test.exs",
      tag: "external_state_delete_guard_mutation",
      test_name: "plain: a runtime DELETE of a retained complete claim gets the guard's refusal",
      assertion: "assert",
      assertion_line: 14,
      required_failures: [
        %{
          test_name:
            "plain: a runtime DELETE of a retained complete claim gets the guard's refusal",
          assertion: "assert",
          assertion_line: 14
        },
        %{
          test_name: "2: a runtime DELETE of a retained complete claim gets the guard's refusal",
          assertion: "assert",
          assertion_line: 14
        }
      ]
    },
    "nonce-guard-inline-eligibility" => %{
      path: "priv/templates/migrations/maintenance/guard_nonce.sql",
      original:
        "  -- rule:nonce-guard-inline-eligibility\n  IF NOT (transaction_timestamp() > OLD.retain_until) THEN",
      mutated:
        "  -- rule:nonce-guard-inline-eligibility\n  IF NOT @routines@.ash_onetime_cleanup_eligible(OLD.retain_until::timestamptz) THEN",
      test: "test/ash_onetime/external_state/delete_guard_test.exs",
      tag: "external_state_delete_guard_mutation",
      test_name: "plain: a runtime DELETE of an unexpired nonce gets the guard's refusal",
      assertion: "assert",
      assertion_line: 37,
      required_failures: [
        %{
          test_name: "plain: a runtime DELETE of an unexpired nonce gets the guard's refusal",
          assertion: "assert",
          assertion_line: 37
        },
        %{
          test_name: "2: a runtime DELETE of an unexpired nonce gets the guard's refusal",
          assertion: "assert",
          assertion_line: 37
        }
      ]
    },
    "lock-l3" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "  # rule:lock-l3\n  defp caller_lock_mode(claim_id) when not is_nil(claim_id), do: \"NO KEY UPDATE\"",
      mutated:
        "  # rule:lock-l3\n  defp caller_lock_mode(claim_id) when not is_nil(claim_id), do: \"UPDATE\"",
      test: "test/ash_onetime/external_state/lock_matrix_test.exs",
      tag: "external_state_lock_matrix_mutation",
      test_name: "plain: P1 a late outcome commits while the caller holds its claim",
      assertion: "assert",
      assertion_line: 100,
      required_failures: [
        %{
          test_name: "plain: P1 a late outcome commits while the caller holds its claim",
          assertion: "assert",
          assertion_line: 100
        },
        %{
          test_name: "2: P1 a late outcome commits while the caller holds its claim",
          assertion: "assert",
          assertion_line: 100
        }
      ]
    },
    "lock-l4" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "  # rule:lock-l4\n  defp caller_lock_mode(nil), do: \"NO KEY UPDATE\"",
      mutated: "  # rule:lock-l4\n  defp caller_lock_mode(nil), do: \"UPDATE\"",
      test: "test/ash_onetime/external_state/lock_matrix_test.exs",
      tag: "external_state_lock_matrix_mutation",
      test_name: "plain: P14 a late outcome commits while the caller holds its claim",
      assertion: "assert",
      assertion_line: 100,
      required_failures: [
        %{
          test_name: "plain: P14 a late outcome commits while the caller holds its claim",
          assertion: "assert",
          assertion_line: 100
        },
        %{
          test_name: "2: P14 a late outcome commits while the caller holds its claim",
          assertion: "assert",
          assertion_line: 100
        }
      ]
    },
    "visibility-helper-settings" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original:
        "-- rule:visibility-helper-settings\nSET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = on",
      mutated:
        "-- rule:visibility-helper-settings\nSET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = on SET lock_timeout = '5s'",
      test: "test/ash_onetime/external_state/policy_degradation_test.exs",
      tag: "external_state_policy_degradation_mutation",
      test_name: "plain/false: a visibility helper inherits the outcome worker's bound",
      assertion: "assert",
      assertion_line: 118,
      required_failures: [
        %{
          test_name: "plain/false: a visibility helper inherits the outcome worker's bound",
          assertion: "assert",
          assertion_line: 118
        },
        %{
          test_name: "plain/true: a visibility helper inherits the outcome worker's bound",
          assertion: "assert",
          assertion_line: 118
        },
        %{
          test_name: "2/false: a visibility helper inherits the outcome worker's bound",
          assertion: "assert",
          assertion_line: 118
        },
        %{
          test_name: "2/true: a visibility helper inherits the outcome worker's bound",
          assertion: "assert",
          assertion_line: 118
        }
      ]
    },
    "rollback-refusal-install" => %{
      path: "priv/templates/migrations/install.exs",
      original:
        "      -- rule:rollback-refusal-install\n      IF EXISTS (SELECT 1 FROM \#{q(\"ash_onetime_idempotency_claims\")} WHERE state='processing' AND NOT effect_local) THEN\n        RAISE EXCEPTION 'unresolved external claims prevent rollback' USING ERRCODE='23514';\n      END IF;",
      mutated: "",
      test: "test/ash_onetime/external_state/upgrade_rollback_test.exs",
      tag: "external_state_upgrade_rollback_mutation",
      test_name: "plain: fresh install rollback refuses an unresolved external claim",
      assertion: "assert",
      assertion_line: 33,
      required_failures: [
        %{
          test_name: "plain: fresh install rollback refuses an unresolved external claim",
          assertion: "assert",
          assertion_line: 33
        },
        %{
          test_name: "2: fresh install rollback refuses an unresolved external claim",
          assertion: "assert",
          assertion_line: 33
        }
      ]
    },
    "claim-trigger-replica-branch" => %{
      tag: "external_state_legacy_archive_mutation",
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "  -- rule:claim-trigger-replica-branch\n  IF TG_OP = 'INSERT'",
      test: "test/ash_onetime/external_state/restore_test.exs",
      assertion_line: 214,
      test_name: "plain: a pre-2.0 archive derives its response deadline in replica mode",
      assertion: "assert",
      mutated:
        "  IF pg_catalog.current_setting('session_replication_role') = 'replica' AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN RETURN NEW; END IF;\n  -- rule:claim-trigger-replica-branch\n  IF TG_OP = 'INSERT'"
    },
    "trust-outcome-holders" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "FROM @routines@.ash_onetime_maintenance_relations() t\n  ), holders",
      mutated:
        "FROM @routines@.ash_onetime_maintenance_relations() t WHERE t<>@outcomes@::regclass AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=t AND inhparent=@outcomes@::regclass)\n  ), holders",
      test: "test/ash_onetime/external_state/outcome_audit_test.exs",
      tag: "external_state_outcome_audit_mutation",
      test_name: "plain: trust refuses outcome UPDATE on root",
      assertion: "assert",
      assertion_line: 29,
      required_failures: [
        %{
          test_name: "plain: trust refuses outcome UPDATE on root",
          assertion: "assert",
          assertion_line: 29
        },
        %{
          test_name: "2: trust refuses outcome UPDATE on root",
          assertion: "assert",
          assertion_line: 29
        }
      ]
    },
    "trust-outcome-column-holders" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "OR has_any_column_privilege(holder.oid,t.oid,\n          -- end-rule:maintenance-effective-column-authority\n            -- rule:maintenance-effective-select-safety\n            -- rule:maintenance-root-column-authority\n            CASE WHEN t.append_only THEN 'UPDATE,REFERENCES' WHEN t.owner_only THEN 'SELECT,INSERT,UPDATE,REFERENCES' ELSE 'REFERENCES' END)",
      mutated: "OR false",
      test: "test/ash_onetime/external_state/outcome_audit_test.exs",
      tag: "external_state_outcome_audit_mutation",
      test_name: "plain: trust refuses outcome column UPDATE",
      assertion: "assert",
      assertion_line: 48,
      required_failures: [
        %{
          test_name: "plain: trust refuses outcome column UPDATE",
          assertion: "assert",
          assertion_line: 48
        },
        %{
          test_name: "2: trust refuses outcome column UPDATE",
          assertion: "assert",
          assertion_line: 48
        }
      ]
    },
    "visibility-helper-acl-audit" => %{
      path: "priv/templates/migrations/maintenance/acl.sql",
      original:
        "    -- rule:visibility-helper-acl-audit\n    SELECT 1 WHERE visibility_oid IS NULL OR EXISTS (\n      SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a\n      WHERE p.oid=visibility_oid AND (a.grantee NOT IN (0,p.proowner) OR a.is_grantable OR a.privilege_type<>'EXECUTE'))\n      OR (SELECT count(*) FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=visibility_oid AND a.grantee IN (0,p.proowner) AND a.privilege_type='EXECUTE' AND NOT a.is_grantable)<>2",
      mutated: "    SELECT 1 WHERE false",
      test: "test/ash_onetime/external_state/outcome_audit_test.exs",
      tag: "external_state_outcome_audit_mutation",
      test_name: "plain: trust refuses a named visibility-helper grant",
      assertion: "assert",
      assertion_line: 72,
      required_failures: [
        %{
          test_name: "plain: trust refuses a named visibility-helper grant",
          assertion: "assert",
          assertion_line: 72
        },
        %{
          test_name: "2: trust refuses a named visibility-helper grant",
          assertion: "assert",
          assertion_line: 72
        }
      ]
    },
    "policy-claim-visibility" => %{
      path: "priv/templates/migrations/maintenance/policy.sql",
      original:
        "    -- rule:policy-claim-visibility\n    AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=r AND p.polname='ash_onetime_claim_visibility'\n      AND p.polpermissive AND p.polcmd='*' AND p.polroles=ARRAY[0::oid]\n      AND @routines@.ash_onetime_maintenance_normalize(p.polqual::text,p.polrelid::oid)='@visibility_expression@'\n      AND @routines@.ash_onetime_maintenance_normalize(p.polwithcheck::text,p.polrelid::oid)='@visibility_expression@');",
      mutated: "    AND false;",
      test: "test/ash_onetime/external_state/outcome_audit_test.exs",
      tag: "external_state_outcome_audit_mutation",
      test_name: "plain: trust refuses an altered visibility expression",
      assertion: "assert",
      assertion_line: 99,
      required_failures: [
        %{
          test_name: "plain: trust refuses an altered visibility expression",
          assertion: "assert",
          assertion_line: 99
        },
        %{
          test_name: "2: trust refuses an altered visibility expression",
          assertion: "assert",
          assertion_line: 99
        }
      ]
    },
    "outcome-acl-column" => %{
      path: "priv/templates/migrations/maintenance/reset_acl.sql",
      original:
        "    -- rule:outcome-acl-column\n    EXECUTE format('REVOKE %s (%I) ON TABLE %s FROM %s CASCADE',\n      CASE WHEN owner_only THEN 'ALL PRIVILEGES' WHEN append_only THEN 'UPDATE, REFERENCES' ELSE 'REFERENCES' END,\n      column_row.attname, target_name,\n      CASE WHEN column_row.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(column_row.grantee)) END);",
      mutated:
        "    IF NOT append_only THEN\n    -- rule:outcome-acl-column\n    EXECUTE format('REVOKE %s (%I) ON TABLE %s FROM %s CASCADE',\n      CASE WHEN owner_only THEN 'ALL PRIVILEGES' WHEN append_only THEN 'UPDATE, REFERENCES' ELSE 'REFERENCES' END,\n      column_row.attname, target_name,\n      CASE WHEN column_row.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(column_row.grantee)) END);\n    END IF;",
      test: "test/ash_onetime/external_state/install_edge_test.exs",
      tag: "external_state_install_edge_mutation",
      test_name:
        "plain: install normalizes append-only privileges and permits the outcome worker",
      assertion: "assert",
      assertion_line: 14,
      required_failures: [
        %{
          test_name:
            "plain: install normalizes append-only privileges and permits the outcome worker",
          assertion: "assert",
          assertion_line: 14
        },
        %{
          test_name:
            "2: install normalizes append-only privileges and permits the outcome worker",
          assertion: "assert",
          assertion_line: 14
        }
      ]
    },
    "outcome-acl-runtime" => %{
      path: "priv/templates/migrations/maintenance/reset_acl.sql",
      original:
        "CASE WHEN owner_only THEN 'ALL PRIVILEGES' WHEN append_only THEN 'UPDATE, DELETE, TRIGGER, TRUNCATE, REFERENCES, MAINTAIN' ELSE 'TRIGGER, TRUNCATE, REFERENCES, MAINTAIN' END",
      mutated:
        "CASE WHEN owner_only THEN 'ALL PRIVILEGES' WHEN append_only THEN 'TRIGGER' ELSE 'TRIGGER, TRUNCATE, REFERENCES, MAINTAIN' END",
      test: "test/ash_onetime/external_state/install_edge_test.exs",
      tag: "external_state_outcome_acl_runtime_mutation",
      test_name: "plain: install normalizes the outcome privilege for its holder",
      assertion: "install audit refused the required normalization",
      assertion_line: 34,
      required_failures: [
        %{
          test_name: "plain: install normalizes the outcome privilege for its holder",
          assertion: "install audit refused the required normalization",
          assertion_line: 34
        },
        %{
          test_name: "2: install normalizes the outcome privilege for its holder",
          assertion: "install audit refused the required normalization",
          assertion_line: 34
        }
      ]
    },
    "acl-outcome-exemption" => %{
      path: "priv/templates/migrations/maintenance/acl.sql",
      original:
        "    WHERE c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner\n      AND (c.oid NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass,@outcomes@::regclass) AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass)\n           OR (c.oid<>@outcomes@::regclass AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass) AND a.privilege_type IN ('TRIGGER','TRUNCATE','REFERENCES','MAINTAIN')))\n",
      mutated:
        "    WHERE c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner\n      AND (c.oid NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass) AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass))\n           OR (c.oid<>@outcomes@::regclass AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass) AND a.privilege_type IN ('TRIGGER','TRUNCATE','REFERENCES','MAINTAIN')))\n",
      test: "test/ash_onetime/external_state/install_edge_test.exs",
      tag: "external_state_install_edge_mutation",
      test_name:
        "plain: install normalizes append-only privileges and permits the outcome worker",
      assertion: "assert",
      assertion_line: 14,
      required_failures: [
        %{
          test_name:
            "plain: install normalizes append-only privileges and permits the outcome worker",
          assertion: "assert",
          assertion_line: 14
        },
        %{
          test_name:
            "2: install normalizes append-only privileges and permits the outcome worker",
          assertion: "assert",
          assertion_line: 14
        }
      ]
    },
    "install-outcome-append-only" => %{
      path: "priv/templates/migrations/maintenance_helpers.exs",
      original:
        "      -- rule:install-outcome-append-only\n      PERFORM \#{rq(\"ash_onetime_maintenance_reset_acl\")}(target.oid,\n        (target.oid NOT IN (format('%I.ash_onetime_idempotency_claims',install_schema)::regclass,\n          format('%I.ash_onetime_nonce_claims',install_schema)::regclass,format('%I.ash_onetime_response_payloads',install_schema)::regclass,format('%I.ash_onetime_effect_outcomes',install_schema)::regclass) AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=target.oid AND inhparent=format('%I.ash_onetime_effect_outcomes',install_schema)::regclass))::boolean);",
      mutated:
        "      -- rule:install-outcome-append-only\n      PERFORM \#{rq(\"ash_onetime_maintenance_reset_acl\")}(target.oid,\n        (target.oid NOT IN (format('%I.ash_onetime_idempotency_claims',install_schema)::regclass,format('%I.ash_onetime_nonce_claims',install_schema)::regclass,format('%I.ash_onetime_response_payloads',install_schema)::regclass))::boolean);",
      test: "test/ash_onetime/external_state/install_edge_test.exs",
      tag: "external_state_install_edge_mutation",
      test_name:
        "plain: install normalizes append-only privileges and permits the outcome worker",
      assertion: "assert",
      assertion_line: 16,
      required_failures: [
        %{
          test_name:
            "plain: install normalizes append-only privileges and permits the outcome worker",
          assertion: "assert",
          assertion_line: 16
        },
        %{
          test_name:
            "2: install normalizes append-only privileges and permits the outcome worker",
          assertion: "assert",
          assertion_line: 16
        }
      ]
    },
    "visibility-helper-public" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original:
        "EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC',routine_oid::regprocedure);",
      mutated:
        "EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC',routine_oid::regprocedure);",
      test: "test/ash_onetime/external_state/install_edge_test.exs",
      tag: "external_state_visibility_helper_public_mutation",
      test_name: "plain: install grants PUBLIC EXECUTE on the visibility helper",
      assertion: "install audit refused the required normalization",
      assertion_line: 40,
      required_failures: [
        %{
          test_name: "plain: install grants PUBLIC EXECUTE on the visibility helper",
          assertion: "install audit refused the required normalization",
          assertion_line: 40
        },
        %{
          test_name: "2: install grants PUBLIC EXECUTE on the visibility helper",
          assertion: "install audit refused the required normalization",
          assertion_line: 40
        }
      ]
    },
    "outcome-rls-follows-claims" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original:
        "      -- rule:outcome-rls-follows-claims\n      IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass) THEN\n        EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',target.oid::regclass);\n      END IF;",
      mutated: "      NULL;",
      test: "test/ash_onetime/external_state/outcome_row_security_test.exs",
      tag: "external_state_outcome_row_security_mutation",
      test_name: "plain: FORCE follows claims and permits the legitimate outcome writer",
      assertion: "assert",
      assertion_line: 13,
      required_failures: [
        %{
          test_name: "plain: FORCE follows claims and permits the legitimate outcome writer",
          assertion: "assert",
          assertion_line: 13
        },
        %{
          test_name: "2: FORCE follows claims and permits the legitimate outcome writer",
          assertion: "assert",
          assertion_line: 13
        }
      ]
    },
    "outcome-bound-invoker" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "INVOKER SET row_security = on",
      mutated: "DEFINER SET row_security = off",
      test: "test/ash_onetime/external_state/outcome_row_security_test.exs",
      tag: "external_state_outcome_row_security_mutation",
      test_name: "plain: FORCE follows claims and permits the legitimate outcome writer",
      assertion: "assert",
      assertion_line: 24,
      required_failures: [
        %{
          test_name: "plain: FORCE follows claims and permits the legitimate outcome writer",
          assertion: "assert",
          assertion_line: 24
        },
        %{
          test_name: "2: FORCE follows claims and permits the legitimate outcome writer",
          assertion: "assert",
          assertion_line: 24
        }
      ]
    },
    "always-claim-trigger" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "ENABLE ALWAYS TRIGGER ash_onetime_idempotency_update_guard",
      mutated: "ENABLE TRIGGER ash_onetime_idempotency_update_guard",
      test: "test/ash_onetime/external_state/logical_replication_test.exs",
      tag: "external_state_logical_claim_insert_mutation",
      test_name: "plain: untrusted logical apply refuses claim_insert",
      assertion: "assert",
      assertion_line: 191,
      required_failures: [
        %{
          test_name: "plain: untrusted logical apply refuses claim_insert",
          assertion: "assert",
          assertion_line: 191
        },
        %{
          test_name: "2: untrusted logical apply refuses claim_insert",
          assertion: "assert",
          assertion_line: 191
        }
      ]
    },
    "always-outcome-guard" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_guard",
      mutated: "ENABLE TRIGGER ash_onetime_effect_outcome_guard",
      test: "test/ash_onetime/external_state/logical_replication_test.exs",
      tag: "external_state_logical_outcome_delete_mutation",
      test_name: "plain: untrusted logical apply refuses outcome_delete",
      assertion: "assert",
      assertion_line: 191,
      required_failures: [
        %{
          test_name: "plain: untrusted logical apply refuses outcome_delete",
          assertion: "assert",
          assertion_line: 191
        },
        %{
          test_name: "2: untrusted logical apply refuses outcome_delete",
          assertion: "assert",
          assertion_line: 191
        }
      ]
    },
    "always-outcome-bound" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_bound",
      mutated: "ENABLE TRIGGER ash_onetime_effect_outcome_bound",
      test: "test/ash_onetime/external_state/logical_replication_test.exs",
      tag: "external_state_logical_outcome_insert_mutation",
      test_name: "plain: untrusted logical apply refuses outcome_insert",
      assertion: "assert",
      assertion_line: 191,
      required_failures: [
        %{
          test_name: "plain: untrusted logical apply refuses outcome_insert",
          assertion: "assert",
          assertion_line: 191
        },
        %{
          test_name: "2: untrusted logical apply refuses outcome_insert",
          assertion: "assert",
          assertion_line: 191
        }
      ]
    },
    "claim-trigger-replica-trusted" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "    AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN",
      mutated: "    THEN",
      test: "test/ash_onetime/external_state/logical_replication_test.exs",
      tag: "external_state_logical_claim_insert_mutation",
      test_name: "plain: untrusted logical apply refuses claim_insert",
      assertion: "assert",
      assertion_line: 191,
      required_failures: [
        %{
          test_name: "plain: untrusted logical apply refuses claim_insert",
          assertion: "assert",
          assertion_line: 191
        },
        %{
          test_name: "2: untrusted logical apply refuses claim_insert",
          assertion: "assert",
          assertion_line: 191
        }
      ]
    },
    "outcome-bound-replica-trusted" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original:
        "    AND pg_catalog.pg_has_role(current_user,(SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID),'SET') THEN",
      mutated: "    THEN",
      test: "test/ash_onetime/external_state/logical_replication_test.exs",
      tag: "external_state_logical_outcome_insert_mutation",
      test_name: "plain: untrusted logical apply refuses outcome_insert",
      assertion: "assert",
      assertion_line: 191,
      required_failures: [
        %{
          test_name: "plain: untrusted logical apply refuses outcome_insert",
          assertion: "assert",
          assertion_line: 191
        },
        %{
          test_name: "2: untrusted logical apply refuses outcome_insert",
          assertion: "assert",
          assertion_line: 191
        }
      ]
    },
    "outcome-guard-update" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "RAISE EXCEPTION 'effect outcome records are immutable' USING ERRCODE='23514';",
      mutated: "NULL;",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: outcome guard refuses update even after an owner grant",
      assertion: "assert",
      assertion_line: 65,
      required_failures: [
        %{
          test_name: "plain: outcome guard refuses update even after an owner grant",
          assertion: "assert",
          assertion_line: 65
        },
        %{
          test_name: "2: outcome guard refuses update even after an owner grant",
          assertion: "assert",
          assertion_line: 65
        }
      ]
    },
    "outcome-guard-parent-lookup" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "WHERE c.id=OLD.claim_id",
      mutated: "WHERE false AND c.id=OLD.claim_id",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: outcome guard sees a parent hidden from the runtime role",
      assertion: "assert",
      assertion_line: 96,
      required_failures: [
        %{
          test_name: "plain: outcome guard sees a parent hidden from the runtime role",
          assertion: "assert",
          assertion_line: 96
        },
        %{
          test_name: "2: outcome guard sees a parent hidden from the runtime role",
          assertion: "assert",
          assertion_line: 96
        }
      ]
    },
    "outcome-guard-row-security" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: " SET row_security = off",
      mutated: "",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: outcome guard fails closed when FORCE hides the parent from its owner",
      assertion: "assert",
      assertion_line: 139,
      required_failures: [
        %{
          test_name:
            "plain: outcome guard fails closed when FORCE hides the parent from its owner",
          assertion: "assert",
          assertion_line: 139
        },
        %{
          test_name: "2: outcome guard fails closed when FORCE hides the parent from its owner",
          assertion: "assert",
          assertion_line: 139
        }
      ]
    },
    "outcome-guard-definer" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "-- rule:outcome-guard-definer\nDEFINER",
      mutated: "-- rule:outcome-guard-definer\nINVOKER",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: outcome guard sees a parent hidden from the runtime role",
      assertion: "assert",
      assertion_line: 96,
      required_failures: [
        %{
          test_name: "plain: outcome guard sees a parent hidden from the runtime role",
          assertion: "assert",
          assertion_line: 96
        },
        %{
          test_name: "2: outcome guard sees a parent hidden from the runtime role",
          assertion: "assert",
          assertion_line: 96
        }
      ]
    },
    "outcome-bound-attempt" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "IF NEW.attempt > granted_attempt THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: the insert bound refuses an ungranted attempt and admits late attempts",
      assertion: "assert",
      assertion_line: 169,
      required_failures: [
        %{
          test_name:
            "plain: the insert bound refuses an ungranted attempt and admits late attempts",
          assertion: "assert",
          assertion_line: 169
        },
        %{
          test_name: "2: the insert bound refuses an ungranted attempt and admits late attempts",
          assertion: "assert",
          assertion_line: 169
        }
      ]
    },
    "outcome-bound-late" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "IF NEW.attempt > granted_attempt THEN",
      mutated: "IF NEW.attempt <> granted_attempt THEN",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: the insert bound refuses an ungranted attempt and admits late attempts",
      assertion: "assert",
      assertion_line: 170,
      required_failures: [
        %{
          test_name:
            "plain: the insert bound refuses an ungranted attempt and admits late attempts",
          assertion: "assert",
          assertion_line: 170
        },
        %{
          test_name: "2: the insert bound refuses an ungranted attempt and admits late attempts",
          assertion: "assert",
          assertion_line: 170
        }
      ]
    },
    "fk-present" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original:
        "  -- rule:fk-present\n  , CONSTRAINT ash_onetime_effect_outcomes_claim_fkey FOREIGN KEY (@key_columns@claim_id)\n    REFERENCES @schema@.ash_onetime_idempotency_claims (@key_columns@id)\n    -- rule:fk-cascade\n    ON DELETE CASCADE",
      mutated: "",
      test: "test/ash_onetime/external_state/outcome_guard_test.exs",
      tag: "external_state_outcome_guard_mutation",
      test_name: "plain: a late outcome cannot outlive its missing parent",
      assertion: "assert",
      assertion_line: 175,
      required_failures: [
        %{
          test_name: "plain: a late outcome cannot outlive its missing parent",
          assertion: "assert",
          assertion_line: 175
        },
        %{
          test_name: "2: a late outcome cannot outlive its missing parent",
          assertion: "assert",
          assertion_line: 175
        }
      ]
    },
    "fk-cascade" => %{
      path: "priv/templates/migrations/external_state/outcomes.sql",
      original: "ON DELETE CASCADE",
      mutated: "ON DELETE NO ACTION",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name:
        "plain: cleanup removes an expired claim with zero payloads and cascades its outcomes",
      assertion: "assert",
      assertion_line: 96,
      required_failures: [
        %{
          test_name:
            "plain: cleanup removes an expired claim with zero payloads and cascades its outcomes",
          assertion: "assert",
          assertion_line: 96
        },
        %{
          test_name:
            "2: cleanup removes an expired claim with zero payloads and cascades its outcomes",
          assertion: "assert",
          assertion_line: 96
        }
      ]
    },
    "verifier-response-retention" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "if response_retention <= retention do",
      mutated: "if true do",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name: "response retention above claim retention refuses the resource",
      assertion: "assert",
      assertion_line: 219
    },
    "cache-ttl-response-deadline" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "response_retain_until: %DateTime{} = response_retain_until",
      mutated: "retain_until: %DateTime{} = response_retain_until",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name: "plain: cache lifetime ends at the response deadline",
      assertion: "assert",
      assertion_line: 160,
      required_failures: [
        %{
          test_name: "plain: cache lifetime ends at the response deadline",
          assertion: "assert",
          assertion_line: 160
        },
        %{
          test_name: "2: cache lifetime ends at the response deadline",
          assertion: "assert",
          assertion_line: 160
        }
      ]
    },
    "reserve-external-kind" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "%{request | effect_local: false}",
      mutated: "%{request | effect_local: true}",
      test: "test/ash_onetime/external_state/grant_test.exs",
      tag: "external_state_grant_mutation",
      test_name: "plain: reservation commits external attempt one",
      assertion: "assert",
      assertion_line: 11,
      required_failures: [
        %{
          test_name: "plain: reservation commits external attempt one",
          assertion: "assert",
          assertion_line: 11
        },
        %{
          test_name: "2: reservation commits external attempt one",
          assertion: "assert",
          assertion_line: 11
        }
      ]
    },
    "grant-attempt-increment" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "SET effect_attempt=effect_attempt+1 WHERE",
      mutated: "SET effect_attempt=effect_attempt WHERE",
      test: "test/ash_onetime/external_state/grant_test.exs",
      tag: "external_state_grant_mutation",
      test_name: "plain: regrant advances unresolved before redispatch",
      assertion: "assert",
      assertion_line: 42,
      required_failures: [
        %{
          test_name: "plain: regrant advances unresolved before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "plain: regrant advances held before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "plain: regrant advances absent_proven before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "plain: regrant advances unknown before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "2: regrant advances unresolved before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "2: regrant advances held before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "2: regrant advances absent_proven before redispatch",
          assertion: "assert",
          assertion_line: 42
        },
        %{
          test_name: "2: regrant advances unknown before redispatch",
          assertion: "assert",
          assertion_line: 42
        }
      ]
    },
    "classify-attempt" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "not locked.effect_local and locked.effect_attempt == granted.effect_attempt ->",
      mutated: "not locked.effect_local ->",
      test: "test/ash_onetime/external_state/attempt_race_test.exs",
      tag: "external_state_attempt_race_mutation",
      test_name: "plain: stale classification refuses before a peer can run",
      assertion: "assert",
      assertion_line: 20,
      required_failures: [
        %{
          test_name: "plain: stale classification refuses before a peer can run",
          assertion: "assert",
          assertion_line: 20
        },
        %{
          test_name: "2: stale classification refuses before a peer can run",
          assertion: "assert",
          assertion_line: 20
        }
      ]
    },
    "classify-complete-replay" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "locked.state == :complete ->",
      mutated:
        "locked.state == :complete -> Result.failure(:request_in_progress, :sent, :open)\n      false ->",
      test: "test/ash_onetime/external_state/attempt_race_test.exs",
      tag: "external_state_attempt_race_mutation",
      test_name: "plain: a late caller replays a completed claim",
      assertion: "assert",
      assertion_line: 27,
      required_failures: [
        %{
          test_name: "plain: a late caller replays a completed claim",
          assertion: "assert",
          assertion_line: 27
        },
        %{
          test_name: "2: a late caller replays a completed claim",
          assertion: "assert",
          assertion_line: 27
        }
      ]
    },
    "completion-attempt-bind" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "do: \" AND effect_attempt = $12::bigint\",",
      mutated: "do: \" AND $12::bigint = $12::bigint\",",
      test: "test/ash_onetime/external_state/attempt_race_test.exs",
      tag: "external_state_attempt_race_mutation",
      test_name: "plain: stale completion rolls its own payload back",
      assertion: "assert",
      assertion_line: 37,
      required_failures: [
        %{
          test_name: "plain: stale completion rolls its own payload back",
          assertion: "assert",
          assertion_line: 37
        },
        %{
          test_name: "2: stale completion rolls its own payload back",
          assertion: "assert",
          assertion_line: 37
        }
      ]
    },
    "outcome-insert-attempt" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "[dump_uuid(claim.id), claim.effect_attempt, Atom.to_string(outcome)]",
      mutated: "[dump_uuid(claim.id), claim.effect_attempt - 1, Atom.to_string(outcome)]",
      test: "test/ash_onetime/external_state/attempt_race_test.exs",
      tag: "external_state_outcome_attempt_mutation",
      test_name: "plain: an outcome records the granted attempt and recovery classifies it held",
      assertion: "assert",
      assertion_line: 91,
      required_failures: [
        %{
          test_name:
            "plain: an outcome records the granted attempt and recovery classifies it held",
          assertion: "assert",
          assertion_line: 91
        },
        %{
          test_name: "2: an outcome records the granted attempt and recovery classifies it held",
          assertion: "assert",
          assertion_line: 91
        }
      ]
    },
    "outcome-worker-timeout" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "with :ok <- arm_claim_lock_timeout(target, lock_timeout_ms),",
      mutated: "with :ok <- :ok,",
      test: "test/ash_onetime/external_state/outcome_connection_test.exs",
      tag: "external_state_outcome_connection_mutation",
      test_name: "plain: B4 the independent outcome worker obeys its lock bound",
      assertion: "assert",
      assertion_line: 90,
      required_failures: [
        %{
          test_name: "plain: B4 the independent outcome worker obeys its lock bound",
          assertion: "assert",
          assertion_line: 90
        },
        %{
          test_name: "2: B4 the independent outcome worker obeys its lock bound",
          assertion: "assert",
          assertion_line: 90
        }
      ]
    },
    "expire-lock-mode" => %{
      path: "priv/templates/migrations/maintenance/expire.sql",
      original: "FOR NO KEY UPDATE SKIP LOCKED",
      mutated: "FOR UPDATE SKIP LOCKED",
      test: "test/ash_onetime/external_state/lock_matrix_test.exs",
      tag: "external_state_lock_matrix_mutation",
      test_name:
        "plain: P7 expiry processes a claim while an uncommitted outcome holds KEY SHARE",
      assertion: "assert",
      assertion_line: 45,
      required_failures: [
        %{
          test_name:
            "plain: P7 expiry processes a claim while an uncommitted outcome holds KEY SHARE",
          assertion: "assert",
          assertion_line: 45
        },
        %{
          test_name:
            "2: P7 expiry processes a claim while an uncommitted outcome holds KEY SHARE",
          assertion: "assert",
          assertion_line: 45
        }
      ]
    },
    "reap-guard-kind" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original:
        "    IF NOT OLD.effect_local THEN\n      RAISE EXCEPTION 'unresolved or unclassified external idempotency claim cannot be deleted' USING ERRCODE='23514';\n    END IF;",
      mutated: "    NULL;",
      test: "test/ash_onetime/external_state/maintenance_survival_test.exs",
      tag: "external_state_maintenance_survival_mutation",
      test_name: "plain: the delete guard refuses an armed direct reap of an external claim",
      assertion: "assert",
      assertion_line: 60,
      required_failures: [
        %{
          test_name: "plain: the delete guard refuses an armed direct reap of an external claim",
          assertion: "assert",
          assertion_line: 60
        },
        %{
          test_name: "2: the delete guard refuses an armed direct reap of an external claim",
          assertion: "assert",
          assertion_line: 60
        }
      ]
    },
    "reap-kind-predicate" => %{
      path: "priv/templates/migrations/maintenance/reap.sql",
      original: "WHERE state='processing' AND effect_local AND inserted_at < reap_before",
      mutated: "WHERE state='processing' AND inserted_at < reap_before",
      test: "test/ash_onetime/external_state/maintenance_survival_test.exs",
      tag: "external_state_maintenance_survival_mutation",
      test_name: "plain: reap finishes beside unresolved, held, absent and unknown claims",
      assertion: "assert",
      assertion_line: 22,
      required_failures: [
        %{
          test_name: "plain: reap finishes beside unresolved, held, absent and unknown claims",
          assertion: "assert",
          assertion_line: 22
        },
        %{
          test_name: "2: reap finishes beside unresolved, held, absent and unknown claims",
          assertion: "assert",
          assertion_line: 22
        }
      ]
    },
    "expire-skips-held" => %{
      path: "priv/templates/migrations/maintenance/expire.sql",
      original: "      AND hold_reference IS NULL",
      mutated: "",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name: "plain: expiry finishes beside held and unexpired responses",
      assertion: "assert",
      assertion_line: 70,
      required_failures: [
        %{
          test_name: "plain: expiry finishes beside held and unexpired responses",
          assertion: "assert",
          assertion_line: 70
        },
        %{
          test_name: "2: expiry finishes beside held and unexpired responses",
          assertion: "assert",
          assertion_line: 70
        }
      ]
    },
    "expire-selects-eligible" => %{
      path: "priv/templates/migrations/maintenance/expire.sql",
      original:
        "      AND @routines@.ash_onetime_cleanup_eligible(response_retain_until::timestamptz)",
      mutated: "",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name: "plain: expiry finishes beside held and unexpired responses",
      assertion: "assert",
      assertion_line: 70,
      required_failures: [
        %{
          test_name: "plain: expiry finishes beside held and unexpired responses",
          assertion: "assert",
          assertion_line: 70
        },
        %{
          test_name: "2: expiry finishes beside held and unexpired responses",
          assertion: "assert",
          assertion_line: 70
        }
      ]
    },
    "expire-payload-cardinality" => %{
      path: "priv/templates/migrations/maintenance/expire.sql",
      original:
        "    IF payload_count<>1 THEN\n      RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE='23514';\n    END IF;",
      mutated: "    NULL;",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name: "plain: expiry refuses a completed claim whose payload was deleted",
      assertion: "assert",
      assertion_line: 115,
      required_failures: [
        %{
          test_name: "plain: expiry refuses a completed claim whose payload was deleted",
          assertion: "assert",
          assertion_line: 115
        },
        %{
          test_name: "2: expiry refuses a completed claim whose payload was deleted",
          assertion: "assert",
          assertion_line: 115
        }
      ]
    },
    "cleanup-expired-payload-count" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original: "(CASE WHEN OLD.response_expired_at IS NULL THEN 1 ELSE 0 END)",
      mutated: "1",
      test: "test/ash_onetime/external_state/response_expiry_test.exs",
      tag: "external_state_response_expiry_mutation",
      test_name:
        "plain: cleanup removes an expired claim with zero payloads and cascades its outcomes",
      assertion: "assert",
      assertion_line: 96,
      required_failures: [
        %{
          test_name:
            "plain: cleanup removes an expired claim with zero payloads and cascades its outcomes",
          assertion: "assert",
          assertion_line: 96
        },
        %{
          test_name:
            "2: cleanup removes an expired claim with zero payloads and cascades its outcomes",
          assertion: "assert",
          assertion_line: 96
        }
      ]
    },
    "claim-trigger-identity-id" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.id IS DISTINCT FROM OLD.id THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity id is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-logical_partition" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.logical_partition IS DISTINCT FROM OLD.logical_partition THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity logical_partition is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-operation_hash" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.operation_hash IS DISTINCT FROM OLD.operation_hash THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity operation_hash is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-scope_hash" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.scope_hash IS DISTINCT FROM OLD.scope_hash THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity scope_hash is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-key_hash" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.key_hash IS DISTINCT FROM OLD.key_hash THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity key_hash is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-fingerprint" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.fingerprint IS DISTINCT FROM OLD.fingerprint THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity fingerprint is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-effect_local" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.effect_local IS DISTINCT FROM OLD.effect_local THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity effect_local is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-admitted_at" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.admitted_at IS DISTINCT FROM OLD.admitted_at THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity admitted_at is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-identity-inserted_at" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "IF NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "identity inserted_at is immutable",
      assertion: "assert",
      assertion_line: 22
    },
    "claim-trigger-insert-shape" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "NEW.state = 'processing' AND NEW.effect_attempt IN (0, 1)",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "insert shape refuses a completed claim and an ungranted attempt",
      assertion: "assert",
      assertion_line: 34
    },
    "claim-trigger-insert-time" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "NEW.admitted_at IS DISTINCT FROM transaction_timestamp()\n      OR NEW.inserted_at IS DISTINCT FROM transaction_timestamp()",
      mutated: "false",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "insert timestamps cannot backdate the retention and abandonment clocks",
      assertion: "assert",
      assertion_line: 40
    },
    "claim-trigger-attempt-step" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "NEW.effect_attempt = OLD.effect_attempt + 1",
      mutated: "NEW.effect_attempt > OLD.effect_attempt",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "attempts advance exactly one while processing",
      assertion: "assert",
      assertion_line: 54
    },
    "claim-trigger-attempt-processing" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "OLD.state = 'processing' AND NEW.state = 'processing'",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "a completed claim cannot grant another attempt",
      assertion: "assert",
      assertion_line: 63
    },
    "claim-trigger-expire-step" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "coalesce(current_setting('ash_onetime.maintenance', true) = 'on', false)\n      AND current_user = (SELECT r.rolname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_roles r ON r.oid=c.relowner WHERE c.oid=TG_RELID)",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "expiry refuses runtime with SQLSTATE 23514",
      assertion: "assert",
      assertion_line: 196
    },
    "claim-trigger-expire-held" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "OLD.hold_reference IS NULL",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "expiry refuses held with SQLSTATE 23514",
      assertion: "assert",
      assertion_line: 196
    },
    "claim-trigger-expire-early" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "transaction_timestamp() > OLD.response_retain_until",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "expiry refuses early with SQLSTATE 23514",
      assertion: "assert",
      assertion_line: 196
    },
    "claim-trigger-expire-payload" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "payload_count = 0",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "expiry refuses payload with SQLSTATE 23514",
      assertion: "assert",
      assertion_line: 196
    },
    "claim-trigger-response-fixed" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "RAISE EXCEPTION 'completed idempotency response is immutable except for maintenance expiry' USING ERRCODE = '23514';",
      mutated: "NULL;",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "completed response refuses a changed response column",
      assertion: "assert",
      assertion_line: 241,
      required_failures: [
        %{
          test_name: "completed response refuses a changed response column",
          assertion: "assert",
          assertion_line: 241
        },
        %{
          test_name: "completed response refuses unexpired complete to processing",
          assertion: "assert",
          assertion_line: 241
        },
        %{
          test_name: "completed response refuses expired response reset with valid columns",
          assertion: "assert",
          assertion_line: 241
        },
        %{
          test_name: "completed response refuses expired complete to processing",
          assertion: "assert",
          assertion_line: 241
        }
      ]
    },
    "claim-trigger-completion-count" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "payload_count = 1",
      mutated: "payload_count >= 1",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "completion requires exactly one payload at the response locator",
      assertion: "assert",
      assertion_line: 146
    },
    "claim-trigger-completion-locator" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: " AND partition_date=NEW.response_partition",
      mutated: "",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "completion requires exactly one payload at the response locator",
      assertion: "assert",
      assertion_line: 138
    },
    "claim-trigger-retain-clamp" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "NEW.retain_until := GREATEST(OLD.retain_until, NEW.retain_until);",
      mutated: "NULL;",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "deadline clamps preserve the original claim and response deadlines",
      assertion: "assert",
      assertion_line: 99
    },
    "claim-trigger-response-retain-clamp" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "NEW.response_retain_until := GREATEST(OLD.response_retain_until, NEW.response_retain_until);",
      mutated: "NULL;",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "response-only deadline clamp preserves the original response deadline",
      assertion: "assert",
      assertion_line: 109
    },
    "claim-trigger-derive-insert" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "NEW.response_retain_until := NEW.retain_until;",
      mutated: "NULL;",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "insert derives a missing response deadline",
      assertion: "assert",
      assertion_line: 113
    },
    "claim-trigger-derive-update" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "NEW.response_retain_until := OLD.response_retain_until\n      + ((extract(epoch FROM NEW.retain_until) - extract(epoch FROM OLD.retain_until)) * interval '1 second');",
      mutated: "NULL;",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "legacy deadline extension moves the response deadline by the same duration",
      assertion: "assert",
      assertion_line: 121
    },
    "claims-check-effect" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "CHECK (NOT effect_local OR effect_attempt = 0)",
      mutated: "CHECK (true)",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "a local claim cannot grant an external attempt",
      assertion: "assert",
      assertion_line: 70
    },
    "claims-check-processing" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "state <> 'processing' OR (response_partition IS NULL AND response_codec IS NULL\n    AND response_digest IS NULL AND response_expired_at IS NULL)",
      mutated: "true",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "processing claims cannot carry response expiry",
      assertion: "assert",
      assertion_line: 77
    },
    "claims-check-expired" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original:
        "response_expired_at IS NOT NULL AND response_partition IS NULL\n    AND response_codec IS NULL AND response_digest IS NULL",
      mutated: "response_expired_at IS NOT NULL",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "expiry must clear all response columns",
      assertion: "assert",
      assertion_line: 211
    },
    "claims-check-deadline-order" => %{
      path: "priv/templates/migrations/external_state/claims.sql",
      original: "CHECK (response_retain_until <= retain_until)",
      mutated: "CHECK (true)",
      test: "test/ash_onetime/external_state/claim_trigger_test.exs",
      tag: "external_state_claim_trigger_mutation",
      test_name: "response deadlines cannot exceed claim deadlines",
      assertion: "assert",
      assertion_line: 84
    },
    "mutation-checker-failure-attribution" => %{
      path: "scripts/mutation_failures.exs",
      original:
        "record[\"test_name\"] == test_name and\n        Path.expand(record[\"file\"]) in Enum.map(List.wrap(mutation.test), &Path.expand/1) and\n        assertion_matches?(record, mutation, assertion)",
      mutated:
        "Enum.any?(records, &(&1[\"test_name\"] == test_name)) and\n        Enum.any?(records, &assertion_matches?(&1, mutation, assertion))",
      test: "test/mutation_check_test.exs",
      tag: "mutation_checker_attribution_mutation",
      test_name: "failure attribution refuses a name and assertion from different failures",
      assertion: "refute AshOnetime.MutationFailures.matches?",
      assertion_line: 17
    },
    "M-doctor-fact-schema" => %{
      tag: "fact_schema_mutation",
      path: "lib/mix/tasks/ash_onetime.doctor.ex",
      original:
        "    WHERE (n.nspname=$1 AND c.relname=ANY($2)) OR EXISTS (\n      SELECT 1 FROM pg_catalog.pg_trigger t\n      WHERE t.tgrelid=c.oid AND t.tgfoid=pg_catalog.to_regprocedure(pg_catalog.format('%I.ash_onetime_fact_append_only()',$1)))",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "trust refuses an ORIGIN fact trigger outside the install schema",
      assertion: "assert doctor_refusal(c)",
      mutated:
        "    WHERE n.nspname=$1 AND (c.relname=ANY($2) OR EXISTS (\n      SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid\n      WHERE t.tgrelid=c.oid AND p.proname='ash_onetime_fact_append_only' AND p.pronamespace=n.oid))",
      assertion_line: 1309
    },
    "M-complete-restore" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "case statement.() do\n        {:error, %Result{transaction: transaction}} = error\n        when transaction in [:rolled_back, :unknown] ->",
      mutated: "case statement.() do\n        {:error, %Result{}} = error ->",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "complete_restore_mutation",
      test_name:
        "non-aborting completion errors restore the timeout before rollback on the same connection",
      assertion: "assert scalar(c.runtime_repo, \"SHOW lock_timeout\") == \"7s\""
    },
    "M-replica-admit-nonce" => %{
      path: "priv/templates/migrations/maintenance/guard_nonce.sql",
      original:
        "    AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET')",
      mutated: "    AND true",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_nonce_mutation",
      test_name: "replica mode refuses untrusted nonce DELETE through its own guard",
      assertion: "assert {:error, %Postgrex.Error"
    },
    "M-replica-lookup-claims-up" => %{
      path: "priv/templates/migrations/operation_hold.exs",
      original:
        "  defp install_hold_functions do\n    execute(\"\"\"\n    CREATE OR REPLACE FUNCTION \#{q(\"ash_onetime_guard_idempotency_delete\")}()\n    RETURNS trigger\n    LANGUAGE plpgsql\n    AS $guard$\n    DECLARE\n      payload_count integer;\n      reap_before text;\n    BEGIN\n      IF pg_catalog.current_setting('session_replication_role') = 'replica'\n        AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN",
      mutated:
        "  defp install_hold_functions do\n    execute(\"\"\"\n    CREATE OR REPLACE FUNCTION \#{q(\"ash_onetime_guard_idempotency_delete\")}()\n    RETURNS trigger\n    LANGUAGE plpgsql\n    AS $guard$\n    DECLARE\n      payload_count integer;\n      reap_before text;\n    BEGIN\n      IF current_setting('session_replication_role') = 'replica'\n        AND pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid=TG_RELID), 'SET') THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "replica_lookup_legacy_mutation",
      test_name: "legacy up claims guard binds replica lookups with nil partitions",
      assertion: "assert {:error, %Postgrex.Error"
    },
    "M-replica-lookup-claims-down" => %{
      path: "priv/templates/migrations/operation_hold.exs",
      original:
        "  defp install_previous_functions do\n    [\n      \"\"\"\n    CREATE OR REPLACE FUNCTION \#{q(\"ash_onetime_guard_idempotency_delete\")}()\n    RETURNS trigger\n    LANGUAGE plpgsql\n    AS $guard$\n    DECLARE\n      payload_count integer;\n      reap_before text;\n    BEGIN\n      IF pg_catalog.current_setting('session_replication_role') = 'replica'\n        AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN",
      mutated:
        "  defp install_previous_functions do\n    [\n      \"\"\"\n    CREATE OR REPLACE FUNCTION \#{q(\"ash_onetime_guard_idempotency_delete\")}()\n    RETURNS trigger\n    LANGUAGE plpgsql\n    AS $guard$\n    DECLARE\n      payload_count integer;\n      reap_before text;\n    BEGIN\n      IF current_setting('session_replication_role') = 'replica'\n        AND pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid=TG_RELID), 'SET') THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "replica_lookup_legacy_mutation",
      test_name: "legacy down claims guard binds replica lookups with nil partitions",
      assertion: "assert {:error, %Postgrex.Error"
    },
    "M-firing-down-claims" => %{
      path: "priv/templates/migrations/maintenance.exs",
      original: "      -- Restored trigger firing modes are part of the rollback contract.\n",
      mutated:
        "      -- Restored trigger firing modes are part of the rollback contract.\n      EXECUTE format('ALTER TABLE %I.ash_onetime_idempotency_claims ENABLE TRIGGER ash_onetime_idempotency_delete_guard',install_schema);\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_down_mutation",
      test_name: "maintenance down restores ALWAYS guards with nil partitions",
      assertion: "assert Enum.all?"
    },
    "M-firing-down-nonce" => %{
      path: "priv/templates/migrations/maintenance.exs",
      original: "      -- Restored trigger firing modes are part of the rollback contract.\n",
      mutated:
        "      -- Restored trigger firing modes are part of the rollback contract.\n      EXECUTE format('ALTER TABLE %I.ash_onetime_nonce_claims ENABLE TRIGGER ash_onetime_nonce_delete_guard',install_schema);\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_down_mutation",
      test_name: "maintenance down restores ALWAYS guards with nil partitions",
      assertion: "assert Enum.all?"
    },
    "M-fact-schema" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "  IF EXISTS (SELECT 1 FROM pg_trigger t\n    WHERE t.tgfoid=to_regprocedure(format('%I.ash_onetime_fact_append_only()',@schema_name@)) AND t.tgenabled<>'A') THEN",
      mutated:
        "  IF EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid\n    WHERE c.relnamespace=to_regnamespace(@schema_name@)\n      AND t.tgfoid=to_regprocedure(format('%I.ash_onetime_fact_append_only()',@schema_name@)) AND t.tgenabled<>'A') THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "fact_schema_mutation",
      test_name: "trust refuses an ORIGIN fact trigger outside the install schema",
      assertion: "assert trust_error(c) =~ \"fact trigger firing mode\""
    },
    "M-fact-upgrade-schema" => %{
      path: "priv/templates/migrations/operation_hold.exs",
      original:
        "      WHERE t.tgfoid=pg_catalog.to_regprocedure($1)\n      \"\"\", [q(\"ash_onetime_fact_append_only\") <> \"()\"]).rows do",
      mutated:
        "      WHERE n.nspname=$1 AND t.tgfoid=pg_catalog.to_regprocedure($2)\n      \"\"\", [prefix() || \"public\", q(\"ash_onetime_fact_append_only\") <> \"()\"]).rows do",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "fact_upgrade_schema_mutation",
      test_name: "operation hold upgrade enables fact triggers outside the install schema",
      assertion: "assert scalar("
    },
    "M-dst-complete" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        ", retain_until = statement_timestamp() + COALESCE($10::bigint, extract(epoch FROM (retain_until - admitted_at))) * interval '1 second'",
      mutated:
        ", retain_until = statement_timestamp() + COALESCE($10::bigint * interval '1 second', (retain_until - admitted_at))",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "dst_complete_mutation",
      test_name:
        "external completion restarts exact elapsed retention across the next backward DST change",
      assertion: "assert SQL.query!",
      assertion_line: 679,
      required_failures:
        for direction <- ["forward", "backward"] do
          %{
            test_name:
              "external completion restarts exact elapsed retention across the next #{direction} DST change",
            assertion:
              if(direction == "forward", do: "assert {:ok, result}", else: "assert SQL.query!"),
            assertion_line: if(direction == "forward", do: 678, else: 679)
          }
        end
    },
    "M-dst-release" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "retain_until = GREATEST(retain_until, statement_timestamp() + extract(epoch FROM (retain_until - admitted_at)) * interval '1 second')",
      mutated:
        "retain_until = GREATEST(retain_until, statement_timestamp() + (retain_until - admitted_at))",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "dst_release_mutation",
      test_name:
        "hold release restarts exact elapsed retention across the next forward DST change",
      assertion: "assert SQL.query!",
      required_failures:
        for direction <- ["forward", "backward"] do
          {"hold release restarts exact elapsed retention across the next #{direction} DST change",
           "assert SQL.query!"}
        end
    },
    "M-complete" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "  defp completion_statement(target, {:external, lock_timeout_ms}, statement) do\n    with {:ok, previous_timeout} <- current_lock_timeout(target),\n         :ok <- arm_claim_lock_timeout(target, lock_timeout_ms) do",
      mutated:
        "  defp completion_statement(target, {:external, _lock_timeout_ms}, statement) do\n    with {:ok, previous_timeout} <- current_lock_timeout(target) do",
      test: [
        "test/ash_onetime/store/postgres_test.exs",
        "test/ash_onetime/external_contention_test.exs"
      ],
      tag: "complete_mutation",
      test_name: "external completion bounds its claim update and retains the committed claim",
      assertion: "assert_receive",
      required_failures: [
        {"external completion bounds its claim update and retains the committed claim",
         "assert_receive"},
        {"external completion bounds its payload insert and reports request in progress",
         "assert_receive"}
      ]
    },
    "M-firing-claims" => %{
      path: "priv/templates/migrations/maintenance_helpers.exs",
      original:
        "      EXECUTE format('ALTER TABLE %I.ash_onetime_idempotency_claims ENABLE ALWAYS TRIGGER ash_onetime_idempotency_delete_guard',install_schema);",
      mutated:
        "      EXECUTE format('ALTER TABLE %I.ash_onetime_idempotency_claims ENABLE TRIGGER ash_onetime_idempotency_delete_guard',install_schema);",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_claims_mutation",
      test_name: "replica mode refuses untrusted claims DELETE through its own guard",
      assertion: "assert {:error, %Postgrex.Error"
    },
    "M-firing-nonce" => %{
      path: "priv/templates/migrations/maintenance_helpers.exs",
      original:
        "      EXECUTE format('ALTER TABLE %I.ash_onetime_nonce_claims ENABLE ALWAYS TRIGGER ash_onetime_nonce_delete_guard',install_schema);",
      mutated:
        "      EXECUTE format('ALTER TABLE %I.ash_onetime_nonce_claims ENABLE TRIGGER ash_onetime_nonce_delete_guard',install_schema);",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_nonce_mutation",
      test_name: "replica mode refuses untrusted nonce DELETE through its own guard",
      assertion: "assert {:error, %Postgrex.Error"
    },
    "M-firing-fact" => %{
      tag: "firing_fact_mutation",
      path: "priv/templates/migrations/fact_tables.exs",
      original:
        "ALTER TABLE \#{q(table)} ENABLE ALWAYS TRIGGER \#{quote_identifier(table <> \"_append_only\")}",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "replica mode refuses untrusted fact DELETE through its own guard",
      assertion: "assert {:error, %Postgrex.Error",
      mutated:
        "ALTER TABLE \#{q(table)} ENABLE TRIGGER \#{quote_identifier(table <> \"_append_only\")}"
    },
    "M-replica-admit" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original:
        "    AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET')",
      mutated: "    AND true",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "replica_admit_mutation",
      test_name:
        "replica admission is restricted and trusted DELETE leaves payload mirroring to apply",
      assertion: "assert {:error, %Postgrex.Error"
    },
    "M-replica-lookup" => %{
      path: "priv/templates/migrations/operation_hold.exs",
      original:
        "    CREATE OR REPLACE FUNCTION \#{q(\"ash_onetime_guard_nonce_delete\")}()\n    RETURNS trigger LANGUAGE plpgsql AS $guard$\n    BEGIN\n      IF pg_catalog.current_setting('session_replication_role') = 'replica'\n        AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN",
      mutated:
        "    CREATE OR REPLACE FUNCTION \#{q(\"ash_onetime_guard_nonce_delete\")}()\n    RETURNS trigger LANGUAGE plpgsql AS $guard$\n    BEGIN\n      IF current_setting('session_replication_role') = 'replica'\n        AND pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid=TG_RELID), 'SET') THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_upgrade_mutation",
      test_name: "operation hold upgrade enables every trigger by function with nil partitions",
      assertion: "assert {:error, %Postgrex.Error",
      required_failures:
        for count <- ["nil", "4"] do
          {"operation hold upgrade enables every trigger by function with #{count} partitions",
           "assert {:error, %Postgrex.Error"}
        end
    },
    "M-firing-upgrade" => %{
      path: "priv/templates/migrations/operation_hold.exs",
      original:
        "    execute(\"ALTER TABLE \#{q(\"ash_onetime_nonce_claims\")} ENABLE ALWAYS TRIGGER ash_onetime_nonce_delete_guard\")",
      mutated:
        "    execute(\"ALTER TABLE \#{q(\"ash_onetime_nonce_claims\")} ENABLE TRIGGER ash_onetime_nonce_delete_guard\")",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "firing_upgrade_mutation",
      test_name: "operation hold upgrade enables every trigger by function with nil partitions",
      assertion: "assert Enum.all?",
      required_failures:
        for count <- ["nil", "4"] do
          {"operation hold upgrade enables every trigger by function with #{count} partitions",
           "assert Enum.all?"}
        end
    },
    "M-contain" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "  ) SELECT classid,objid,identity FROM objects\n    UNION SELECT 'pg_namespace'::regclass,n.oid,'schema ' || quote_ident(n.nspname)\n      FROM objects o JOIN pg_namespace n ON n.nspname=o.schema\n    ORDER BY 1,2\n",
      mutated: "  ) SELECT classid,objid,identity FROM objects WHERE false\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "contain_mutation",
      test_name:
        "containment refuses an untrusted table schema owner with a real cascade control",
      assertion: "assert error =~ \"containment\""
    },
    "M-holder" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "    IF object_owner<>@owner@ THEN\n      SELECT r.rolname INTO holder_name FROM pg_roles r\n      WHERE pg_has_role(r.oid,authority_owner,'MEMBER') AND NOT r.rolsuper\n        AND NOT pg_has_role(r.oid,@owner@,'MEMBER') ORDER BY r.rolname LIMIT 1;\n      IF FOUND THEN\n        RAISE EXCEPTION 'untrusted_dependency: containment object %, owner %, authority owner %, holder %',\n          containment_object.identity,owner_name,pg_get_userbyid(authority_owner),holder_name;\n      END IF;\n    END IF;\n",
      mutated: "",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "holder_mutation",
      test_name: "containment refuses a superuser schema owner's inherit holder",
      assertion: "assert error =~ \"holder\""
    },
    "M-internal" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "      UNION SELECT d.classid,d.objid FROM pg_depend d WHERE d.refclassid=c.classid AND d.refobjid=c.objid AND d.deptype='i'\n",
      mutated: "",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "internal_mutation",
      test_name: "containment follows internal row types into extension membership",
      assertion: "assert error =~ \"containment\""
    },
    "M-extmember" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "      UNION SELECT d.classid,d.objid FROM pg_depend d WHERE c.classid='pg_extension'::regclass AND d.refclassid=c.classid AND d.refobjid=c.objid AND d.deptype='e'\n",
      mutated: "",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "extmember_mutation",
      test_name: "containment follows extension members into their untrusted schema",
      assertion: "assert error =~ \"containment\""
    },
    "M-oid" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "    ) next\n",
      mutated: "    ) next WHERE next.objid>=16384 OR next.classid='pg_namespace'::regclass\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "oid_mutation",
      test_name: "containment follows low-OID plpgsql extension members into their schema",
      assertion: "assert error =~ \"containment\""
    },
    "M-evt-trust" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "  -- Event-trigger code runs under DDL and login identities, even outside the\n  -- relation graph. Disabled triggers remain an authority held by their owner.\n  SELECT e.evtname,p.oid::regprocedure AS function_name,r.rolname AS owner_name,\n    holder.rolname AS holder INTO ownership_error\n  FROM pg_event_trigger e JOIN pg_proc p ON p.oid=e.evtfoid JOIN pg_roles r ON r.oid=p.proowner\n  CROSS JOIN pg_database db JOIN pg_roles dbowner ON dbowner.oid=db.datdba\n  LEFT JOIN LATERAL (\n    SELECT h.rolname FROM pg_roles h\n    WHERE pg_has_role(h.oid,CASE WHEN r.rolname='pg_database_owner' THEN db.datdba ELSE r.oid END,'MEMBER')\n      AND NOT h.rolsuper AND NOT pg_has_role(h.oid,@owner@,'MEMBER')\n    ORDER BY h.rolname LIMIT 1\n  ) holder ON r.oid<>@owner@\n  WHERE db.datname=current_database() AND (\n    NOT (r.oid=@owner@ OR r.rolsuper OR (r.rolname='pg_database_owner' AND (db.datdba=@owner@ OR dbowner.rolsuper)))\n    OR holder.rolname IS NOT NULL)\n  ORDER BY e.evtname LIMIT 1;\n  IF FOUND THEN\n    RAISE EXCEPTION 'untrusted_dependency: event trigger %, function %, owner %, holder %',\n      ownership_error.evtname,ownership_error.function_name,ownership_error.owner_name,ownership_error.holder;\n  END IF;\n  -- End event-trigger ownership.\n",
      mutated: "",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "evt_trust_mutation",
      test_name: "trust and doctor audit ddl_command_start event code and its execution identity",
      assertion: "assert error =~ event",
      required_failures:
        for event <- ["ddl_command_start", "login"] do
          {"trust and doctor audit #{event} event code and its execution identity",
           "assert error =~ event"}
        end
    },
    "M-evt-doctor" => %{
      path: "lib/mix/tasks/ash_onetime.doctor.ex",
      original: "Enum.map(facts.event_owners, fn",
      mutated: "Enum.map([], fn",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "evt_doctor_mutation",
      test_name: "trust and doctor audit ddl_command_start event code and its execution identity",
      assertion: "Expected exception Mix.Error",
      required_failures:
        for event <- ["ddl_command_start", "login"] do
          {"trust and doctor audit #{event} event code and its execution identity",
           "Expected exception Mix.Error"}
        end
    },
    "M-doctor-runtime" => %{
      path: "lib/mix/tasks/ash_onetime.doctor.ex",
      original: "Enum.flat_map(facts.runtime_owner, fn",
      mutated: "Enum.flat_map([], fn",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "doctor_runtime_mutation",
      test_name: "live doctor refuses its cold runtime role's owner equivalence",
      assertion: "Expected exception Mix.Error"
    },
    "maintenance-effective-admin-predefined" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "pg_has_role(r.oid,holder.oid,'MEMBER')",
      mutated: "pg_has_role(r.oid,holder.oid,'SET')",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_admin_authority_mutation",
      test_name: "effective authority refuses ADMIN-only predefined membership",
      assertion: "refute scalar("
    },
    "maintenance-effective-admin-group" => %{
      tag: "effective_admin_authority_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "left(holder.rolname,3)<>'pg_' OR EXISTS (\n    -- end-rule:maintenance-effective-proxy-holder\n    -- end-rule:maintenance-effective-unreachable-holder\n      SELECT 1 FROM pg_roles r WHERE pg_has_role(r.oid,holder.oid,'MEMBER')\n        AND (r.rolcanlogin OR r.oid IN (SELECT oid FROM scheduled)\n          OR r.rolname=current_setting('role') OR r.rolname=current_user OR r.rolname=session_user)\n        AND NOT r.rolsuper AND r.oid<>@owner@\n        AND NOT pg_has_role(r.oid,@owner@,'USAGE') AND NOT pg_has_role(r.oid,@owner@,'SET')\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "effective authority refuses ADMIN-only group membership",
      assertion: "refute scalar(",
      mutated:
        "false OR EXISTS (\n      SELECT 1 FROM pg_roles r WHERE pg_has_role(r.oid,holder.oid,'SET')\n        AND (r.rolcanlogin OR r.oid IN (SELECT oid FROM scheduled)\n          OR r.rolname=current_setting('role') OR r.rolname=current_user OR r.rolname=session_user)\n        AND NOT r.rolsuper AND r.oid<>@owner@\n        AND NOT pg_has_role(r.oid,@owner@,'USAGE') AND NOT pg_has_role(r.oid,@owner@,'SET')\n",
      assertion_line: 1679
    },
    "maintenance-effective-unreachable-holder" => %{
      tag: "effective_unreachable_authority_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "left(holder.rolname,3)<>'pg_'",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "effective authority refuses an unreachable group holder",
      assertion: "refute scalar(",
      mutated: "false",
      assertion_line: 5557
    },
    "maintenance-effective-proxy-holder" => %{
      tag: "effective_proxy_authority_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "left(holder.rolname,3)<>'pg_'",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name:
        "effective authority refuses an unreachable holder exposed through a PUBLIC view",
      assertion: "refute scalar(",
      mutated: "false",
      assertion_line: 1754
    },
    "maintenance-effective-subscription-role" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "WHEN pg_has_role(holder.oid,'pg_create_subscription','MEMBER')",
      mutated: "WHEN false",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_subscription_role_mutation",
      test_name: "effective authority refuses pg_create_subscription via inherit",
      assertion: "refute scalar(",
      required_failures: [
        {"effective authority refuses pg_create_subscription via inherit", "refute scalar("},
        {"effective authority refuses pg_create_subscription via admin", "refute scalar("}
      ]
    },
    "maintenance-effective-subscription-owner" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "WHERE s.subdbid=(SELECT oid FROM pg_database WHERE datname=current_database())",
      mutated:
        "WHERE false AND s.subdbid=(SELECT oid FROM pg_database WHERE datname=current_database())",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_subscription_owner_mutation",
      test_name: "effective authority refuses an existing untrusted subscription owner",
      assertion: "refute scalar("
    },
    "maintenance-effective-alter-system" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "'session_replication_role','SET, ALTER SYSTEM'",
      mutated: "'session_replication_role','SET'",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_alter_system_mutation",
      test_name: "effective parameter authority refuses ALTER SYSTEM without SET",
      assertion: "refute scalar("
    },
    "maintenance-effective-select-safety" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "WHEN t.owner_only THEN 'SELECT,INSERT,UPDATE,REFERENCES'",
      mutated: "WHEN t.owner_only THEN 'INSERT,UPDATE,REFERENCES'",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_select_safety_mutation",
      test_name:
        "SELECT stays refused because existing children do not share root RLS and policies",
      assertion: "refute scalar("
    },
    "maintenance-effective-root-authority" => %{
      tag: "effective_root_authority_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "CASE WHEN t.append_only OR t.owner_only THEN 'DELETE,TRIGGER,TRUNCATE' ELSE 'TRIGGER,TRUNCATE' END",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "effective root authority refuses TRIGGER on ash_onetime_idempotency_claims",
      assertion: "refute scalar(",
      mutated:
        "CASE WHEN t.append_only OR t.owner_only THEN 'DELETE,TRIGGER,TRUNCATE' ELSE 'TRIGGER WITH GRANT OPTION,TRUNCATE WITH GRANT OPTION' END",
      assertion_line: 5557
    },
    "maintenance-effective-cluster-isolation" => %{
      path: "test/support/cluster_isolation.ex",
      original: "unless is_binary(expected) and String.trim(hostname) == expected do",
      mutated: "unless true do",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_cluster_isolation_mutation",
      test_name: "cluster grant isolation refuses an unproven server",
      assertion: "Expected exception RuntimeError"
    },
    "maintenance-effective-cluster-isolation-run" => %{
      path: "test/support/cluster_isolation.ex",
      original: "if System.get_env(\"GITHUB_ACTIONS\") == \"true\" do",
      mutated: "if false do",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_cluster_isolation_mutation",
      test_name: "cluster grant isolation refuses an unproven server",
      assertion: "Expected exception RuntimeError"
    },
    "claim-load-payload-timeout-restore" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "  defp select_claim_under_timeout(target, claim, claim_id, lock_timeout_ms) do\n    with {:ok, previous} <- current_lock_timeout(target),\n         :ok <- arm_claim_lock_timeout(target, lock_timeout_ms) do\n",
      mutated:
        "  defp select_claim_under_timeout(target, claim, claim_id, lock_timeout_ms) do\n    with {:ok, previous} <- current_lock_timeout(target),\n         :ok <- arm_claim_lock_timeout(target, lock_timeout_ms) do\n      restore_lock_timeout(target, previous)\n",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "claim_load_payload_restore_mutation",
      test_name:
        "completed claim load bounds its joined payload read and restores the caller timeout",
      assertion: "assert observed == [[\"100ms\"]]"
    },
    "maintenance-effective-column-authority" => %{
      tag: "effective_select_safety_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "OR has_any_column_privilege(holder.oid,t.oid,",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name:
        "SELECT stays refused because existing children do not share root RLS and policies",
      assertion: "refute scalar(",
      mutated: "OR false AND has_any_column_privilege(holder.oid,t.oid,",
      assertion_line: 1981
    },
    "maintenance-effective-relation-authority" => %{
      tag: "enforcement_table_authority_predicate_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "(has_table_privilege(holder.oid,t.oid,",
      test: "test/ash_onetime/external_state/authority_predicates_test.exs",
      test_name: "plain: a table-only DELETE holder is refused",
      assertion: "assert",
      mutated: "(false AND has_table_privilege(holder.oid,t.oid,",
      assertion_line: 20
    },
    "maintenance-effective-replication-authority" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "WHEN has_parameter_privilege(holder.oid,'session_replication_role','SET, ALTER SYSTEM')",
      mutated: "WHEN false",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "effective_replication_authority_mutation",
      test_name: "effective replication parameter authority refuses direct SET grant",
      assertion: "refute scalar(",
      required_failures:
        for membership <- [:direct, :group] do
          {"effective replication parameter authority refuses #{membership} SET grant",
           "refute scalar("}
        end
    },
    "external-replay-lock-timeout" => %{
      tag: "external_replay_lock_timeout_mutation",
      path: "lib/ash_onetime/store/postgres.ex",
      original: "               nil,\n               Keyword.get(options, :lock_timeout_ms)",
      test: "test/ash_onetime/external_contention_test.exs",
      test_name: "immediate replay bounds its first claim lock and reports request in progress",
      assertion: "assert_receive {:external_done, ^caller,",
      mutated: "               nil,\n               nil",
      assertion_line: 124
    },
    "claim-load-timeout-restore" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "          restore_lock_timeout(target, previous)",
      mutated: "          restore_lock_timeout(target, to_string(byte_size(previous)) <> \"ms\")",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "claim_load_restore_mutation",
      test_name: "claim load restores the caller lock timeout before later statements",
      assertion: "assert SQL.query!(Repo, \"SHOW lock_timeout\", []).rows == [[\"7s\"]]"
    },
    "replay-callback-error-rollback" => %{
      path: "lib/ash_onetime/change.ex",
      original: "Ash.DataLayer.rollback(changeset.resource, callback_error)",
      mutated: "{:error, callback_error}",
      test: "test/ash_onetime/replay_relationship_callback_error_test.exs",
      tag: "replay_callback_error_mutation",
      test_name: "create replay rolls back writes and preserves an after-action error",
      assertion: "assert %{rows: [[^markers, ^related]]} =",
      required_failures:
        Enum.map([:create, :update, :destroy], fn action ->
          {"#{action} replay rolls back writes and preserves an after-action error",
           "assert %{rows: [[^markers, ^related]]} ="}
        end) ++
          [
            {"replay rolls back writes when a policy rejects the result",
             "assert %{rows: [[^markers, ^related]]} ="},
            {"replay rolls back partial relationship management",
             "assert %{rows: [[^markers, ^related]]} ="}
          ]
    },
    "replay-relationship-clearing" => %{
      path: "lib/ash_onetime/change.ex",
      original: "&Ash.Changeset.clear_change(&2, &1)",
      mutated: "fn _relationship, pending -> pending end",
      test: "test/ash_onetime/replay_relationship_test.exs",
      tag: "replay_relationship_clear_mutation",
      test_name: "create replay clears caller-managed children and returns the stored result",
      assertion: "assert {:ok, replayed} =",
      required_failures:
        for action <- [:create, :update, :destroy], relationship <- [:children, :owner] do
          {"#{action} replay clears caller-managed #{relationship} and returns the stored result",
           "assert {:ok, replayed} ="}
        end
    },
    "replay-relationship-rollback" => %{
      path: "lib/ash_onetime/change.ex",
      original: "Ash.DataLayer.rollback(final_changeset.resource, error)",
      mutated: "{:error, error}",
      test: "test/ash_onetime/replay_relationship_test.exs",
      tag: "replay_relationship_backstop_mutation",
      test_name: "create replay rolls back a lying pure hook even with rollback_on_error?: false",
      assertion: "assert %{rows: [[0]]} =",
      required_failures:
        for action <- [:create, :update, :destroy] do
          {"#{action} replay rolls back a lying pure hook even with rollback_on_error?: false",
           "assert %{rows: [[0]]} ="}
        end
    },
    "generic-replay-relationship-backstop" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "Map.get(input, :relationships, %{}) == %{}",
      mutated: "true",
      test: "test/ash_onetime/replay_relationship_test.exs",
      tag: "generic_replay_relationship_mutation",
      test_name: "generic completion rolls back relationship state injected by a caller hook",
      assertion: "assert {:error, error} = Ash.run_action(replay)"
    },
    "maintenance-runtime-maintain" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "OR r.oid IN (SELECT oid FROM scheduled)",
      mutated: "OR false",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "review_inactive_runtime",
      test_name: "inactive NOLOGIN runtime member with SET only MAINTAIN refuses maintenance",
      assertion: "SQL.query(c.owner_repo"
    },
    "maintenance-routine-acl" => %{
      path: "priv/templates/migrations/maintenance/acl.sql",
      original: "nspname=@routine_schema_name@",
      mutated: "nspname=@schema_name@",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "review_acl",
      test_name: "routine ACL audit distinguishes outsider",
      assertion: "@grant == :table_schema_name",
      required_failures:
        for grant <- [:outsider, :grant_option, :table_schema_name] do
          {"routine ACL audit distinguishes #{grant}", "@grant == :table_schema_name"}
        end
    },
    "maintenance-set-maintain" => %{
      tag: "review_set_maintain",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "WHEN EXISTS (SELECT 1 FROM relations t WHERE has_table_privilege(holder.oid,t.oid,'MAINTAIN'))",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "SET only MAINTAIN through pg_maintain refuses maintenance",
      assertion: "assert_refusal",
      mutated: "WHEN false",
      assertion_line: 4679
    },
    "maintenance-upgrade-validation" => %{
      tag: "enforcement_maintenance_upgrade_validation_mutation",
      path: "priv/templates/migrations/maintenance_helpers.exs",
      original:
        "RAISE EXCEPTION 'untrusted_dependency: upgrade relation shape %',target.relname;",
      test: "test/ash_onetime/external_state/install_mismatch_test.exs",
      test_name: "plain: maintenance upgrade authenticates the current relation shape",
      assertion: "assert error.postgres.message ==",
      mutated: "NULL; -- bypass historical validation",
      assertion_line: 59,
      required_failures: [
        %{
          test_name: "plain: maintenance upgrade authenticates the current relation shape",
          assertion: "assert error.postgres.message ==",
          assertion_line: 59
        },
        %{
          test_name: "2: maintenance upgrade authenticates the current relation shape",
          assertion: "assert error.postgres.message ==",
          assertion_line: 59
        }
      ]
    },
    "maintenance-upgrade-constraint-count" => %{
      tag: "shipped_upgrade_tamper",
      path: "priv/templates/migrations/external_state.exs",
      original:
        "          OR jsonb_array_length(actual_shape->'constraints')<>jsonb_array_length(expected_shape->'constraints')\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      assertion_line: 3753,
      test_name: "historical upgrade refuses changed extra_duplicate_check without adopting it",
      assertion: "Expected exception Postgrex.Error but nothing was raised",
      mutated: ""
    },
    "maintenance-upgrade-constraint-coverage" => %{
      tag: "shipped_upgrade_tamper",
      path: "priv/templates/migrations/external_state.exs",
      original:
        "          OR EXISTS (SELECT 1 FROM jsonb_array_elements(expected_shape->'constraints') e\n            WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(actual_shape->'constraints') x\n              WHERE x=e OR ((historical_shape->'constraints') @> jsonb_build_array(x)\n                AND (x-'expression'=e-'expression' OR (x->>'type'='p' AND e->>'type'='p')))))",
      test: "test/ash_onetime/store/maintenance_test.exs",
      assertion_line: 3753,
      test_name: "historical upgrade refuses changed duplicate_check without adopting it",
      assertion: "Expected exception Postgrex.Error but nothing was raised",
      mutated: ""
    },
    "maintenance-logical-primary" => %{
      path: "priv/templates/migrations/external_state.exs",
      original: "IF historical_key THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shipped_primary_mutation",
      test_name: "shipped schema upgrades and restores: v0.1.0, claims 2",
      assertion:
        "ERROR 42830 (invalid_foreign_key) there is no unique constraint matching given keys"
    },
    "maintenance-upgrade-check-names" => %{
      path: "priv/templates/migrations/external_state.exs",
      original:
        "FOR check_ddl IN SELECT conname AS name FROM pg_constraint WHERE conrelid=target.oid AND contype='c' LOOP",
      mutated:
        "FOR check_ddl IN SELECT key AS name FROM jsonb_each_text(manifest->(target.relname || '_check_ddl')) LOOP",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shipped_check_names",
      test_name: "historical upgrade replaces validated CHECKs by their actual catalog names",
      assertion: "does not exist"
    },
    "maintenance-upgrade-reference" => %{
      tag: "review_install_mode",
      path: "priv/templates/migrations/maintenance_helpers.exs",
      original: "-- rule:maintenance-upgrade-reference\n    IF \#{mode == :fresh} THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "upgrade with missing old routines refuses an existing hostile trigger",
      assertion: "assert_raise Postgrex.Error",
      mutated:
        "-- rule:maintenance-upgrade-reference\n    IF jsonb_array_length(old_functions)=0 THEN",
      assertion_line: 2078
    },
    "maintenance-shape-type" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original: "'type',a.atttypid",
      mutated: "'type',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_base_type_mutation",
      test_name: "Table 1 row 15: base_type refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-typmod" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original: "'typmod',a.atttypmod",
      mutated: "'typmod',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_typmod_mutation",
      test_name: "Table 1 row 15: typmod refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-collation" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original: "'collation',a.attcollation",
      mutated: "'collation',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_collation_mutation",
      test_name: "Table 1 row 18: collation refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-default" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original:
        "'default',@routines@.ash_onetime_maintenance_normalize(d.adbin::text,relation_oid::oid)",
      mutated: "'default',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_default_mutation",
      test_name: "Table 1 row 6: default refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-opclass" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original: "'opclasses',i.indclass::text",
      mutated: "'opclasses',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_operator_family_mutation",
      test_name: "Table 1 row 13: operator_family refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-index-am" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original: "'am',ic.relam",
      mutated: "'am',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_access_method_mutation",
      test_name: "Table 1 row 22: access_method refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-index-expressions" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original:
        "'expressions',@routines@.ash_onetime_maintenance_normalize(i.indexprs::text,relation_oid::oid)",
      mutated: "'expressions',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_index_mutation",
      test_name: "Table 1 row 11: index refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-shape-constraint-expression" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original:
        "'expression',@routines@.ash_onetime_maintenance_normalize(x.conbin::text,relation_oid::oid)",
      mutated: "'expression',NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "shape_check_mutation",
      test_name: "Table 1 row 8: check refuses before owner code runs",
      assertion: "compared_field(before, @kind)"
    },
    "maintenance-normalize-location" => %{
      path: "priv/templates/migrations/maintenance/normalize.sql",
      original: "regexp_replace(tree, ':location [-0-9]+', ':location -1', 'g')",
      mutated: "tree",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "normalize_location_mutation",
      test_name: "Table 1 row 6: default refuses before owner code runs",
      assertion: "assert normalize.(located) == normalize.(tree)"
    },
    "maintenance-normalize-oid" => %{
      path: "priv/templates/migrations/maintenance/normalize.sql",
      original:
        "result := regexp_replace(result, '(:[a-z]+) ' || object_row.oid || '( |})', '\\1 ' || object_row.identity || '\\2','g');",
      mutated: "result := result;",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "restore_fixpoint",
      test_name: "every package expression is a PostgreSQL 18 dump restore fixpoint, default",
      assertion: "assert normalized_policies(c) == policies"
    },
    "maintenance-normalize-referenced" => %{
      path: "priv/templates/migrations/maintenance/normalize.sql",
      original: "WHERE m.captures[1]::bigint <= 4294967295;",
      mutated: "WHERE false;",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "restore_fixpoint",
      test_name: "every package expression is a PostgreSQL 18 dump restore fixpoint, default",
      assertion: "assert normalized_policies(c) == policies"
    },
    "maintenance-normalize-attnum" => %{
      path: "priv/templates/migrations/maintenance/normalize.sql",
      original:
        "    result := regexp_replace(result, ':(varattno|varattnosyn) ' || column_row.attnum || '( |})',\n      ':\\1 ' || quote_ident(column_row.attname) || '\\2', 'g');",
      mutated: "    result := result;",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "normalize_attnum_mutation",
      test_name: "ADD COLUMN upgrade uses a same-server reference and maps attribute numbers",
      assertion: "untrusted_dependency: upgrade relation shape"
    },
    "maintenance-restore-fixpoint" => %{
      path: "priv/templates/migrations/maintenance/shape.sql",
      original: "x.contype IN ('p','u','x') AND c.relkind='r' AND c.relispartition",
      mutated: "false",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "restore_fixpoint",
      test_name: "every package expression is a PostgreSQL 18 dump restore fixpoint, default",
      assertion: "assert relation_shapes(c) == shapes",
      required_failures:
        for variant <- [:default, :hash, :facts, :logical_partitions, :prefix] do
          {"every package expression is a PostgreSQL 18 dump restore fixpoint, #{variant}",
           "assert relation_shapes(c) == shapes"}
        end,
      red_summary: "Result: 0/6 passed",
      green_summary: "Result: 6 passed"
    },
    "maintenance-routine-schema" => %{
      tag: "routine_schema_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "AND has_schema_privilege(r.oid,@routine_schema_name@,'CREATE')",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "effective routine schema CREATE refuses an untrusted runtime grant",
      assertion: "assert_refusal",
      mutated: "AND false",
      assertion_line: 4679
    },
    "maintenance-publication-filter" => %{
      tag: "publication_filter_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "p.prqual IS NOT NULL",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "publication membership permits no filter and refuses a row filter",
      assertion: "assert_refusal",
      mutated: "false",
      assertion_line: 4679
    },
    "maintenance-owner-membership" => %{
      tag: "routine_owner_membership_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "AND pg_has_role(r.oid,@owner@,'MEMBER')",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "maintenance refuses owner membership for runtime, INHERIT=true",
      assertion: "assert_refusal",
      mutated: "AND false",
      assertion_line: 4679
    },
    "maintenance-name-collision" => %{
      tag: "collision",
      path: "priv/templates/migrations/maintenance/roll.sql",
      original: "RAISE EXCEPTION 'untrusted_dependency: name collision';",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name:
        "Table 1 row 33: roll refuses a colliding standalone table without adopting or executing it",
      assertion: "assert_refusal",
      mutated: "RAISE duplicate_table;",
      assertion_line: 4679
    },
    "maintenance-shape" => %{
      tag: "maintenance_shape_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "WHERE true -- R1 relation set",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "a builtin array input cannot dispatch a runtime domain check",
      assertion: "assert_refusal",
      mutated: "WHERE false -- R1 relation set",
      assertion_line: 4679
    },
    "maintenance-check-before-lock" => %{
      path: ~S|priv/templates/migrations/maintenance/cleanup_nonce.sql|,
      original:
        "  PERFORM @routines@.ash_onetime_maintenance_lock(false::boolean, 5000::integer);\n  PERFORM @routines@.ash_onetime_maintenance_trust();",
      mutated:
        "  PERFORM @routines@.ash_onetime_maintenance_trust();\n  PERFORM @routines@.ash_onetime_maintenance_lock(false::boolean, 5000::integer);",
      test: ~S|test/ash_onetime/store/maintenance_test.exs|,
      tag: ~S|maintenance_lock_mutation|,
      test_name: ~S|recursive locks exclude concurrent inheritance before the check|,
      assertion: ~S|assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}}|
    },
    "maintenance-recursive-lock" => %{
      path: ~S|priv/templates/migrations/maintenance/lock.sql|,
      original: ~S|IN SHARE UPDATE EXCLUSIVE MODE|,
      mutated: ~S|IN ROW EXCLUSIVE MODE|,
      test: ~S|test/ash_onetime/store/maintenance_test.exs|,
      tag: ~S|maintenance_lock_mutation|,
      test_name: ~S|recursive locks exclude concurrent inheritance before the check|,
      assertion: ~S|assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}}|
    },
    "maintenance-acl-reset" => %{
      path: ~S|priv/templates/migrations/maintenance/roll.sql|,
      original:
        ~S|PERFORM @routines@.ash_onetime_maintenance_reset_acl(child_oid::oid,true::boolean);|,
      mutated: ~S|NULL;|,
      test: ~S|test/ash_onetime/store/maintenance_test.exs|,
      tag: ~S|rls_child_policy_copy_mutation|,
      test_name: ~S|forward roll copies policies and flags and resets table and column ACLs|,
      assertion: ~S|refute SQL.query!|
    },
    "maintenance-maintain" => %{
      tag: "maintenance_maintain_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "RAISE EXCEPTION 'untrusted_dependency: effective MAINTAIN privilege on % for role %',authority_relation,authority_holder;",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "effective MAINTAIN audit covers pg_maintain and install revokes direct ANALYZE",
      assertion: "assert {:error",
      mutated: "NULL;",
      assertion_line: 4679
    },
    "maintenance-policy" => %{
      tag: "maintenance_policy_mutation",
      path: "priv/templates/migrations/maintenance/policy.sql",
      original: "IF offending <> '' THEN RETURN offending; END IF;",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "Table 1 row 5: an owner-applicable policy cannot execute runtime-owned code",
      assertion: "assert_refusal",
      mutated: "IF false THEN RETURN offending; END IF;",
      assertion_line: 4679
    },
    "maintenance-digest" => %{
      tag: "maintenance_digest_mutation",
      path: "priv/templates/migrations/maintenance/trust.sql",
      original:
        "OR encode(sha256(convert_to(p.prosrc,'UTF8')),'hex') IS DISTINCT FROM m->>'digest'",
      test: "test/ash_onetime/store/maintenance_test.exs",
      test_name: "package routine identity also requires its exact source digest",
      assertion: "assert_refusal",
      mutated: "OR false",
      assertion_line: 4679
    },
    "maintenance-null-bound" => %{
      path: ~S|priv/templates/migrations/maintenance/roll.sql|,
      original: ~S|months_ahead IS NULL OR months_ahead<1|,
      mutated: ~S|months_ahead<1|,
      test: ~S|test/ash_onetime/store/maintenance_test.exs|,
      tag: ~S|maintenance_isolation_mutation|,
      test_name: ~S|SQL rejects NULL and out of range bounds and repeatable read|,
      assertion: ~S|assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023"}}}|
    },
    "maintenance-heap" => %{
      path: ~S|priv/templates/migrations/maintenance/roll.sql|,
      original: "EXECUTE create_child || ' USING heap';",
      mutated: ~S|EXECUTE create_child;|,
      test: ~S|test/ash_onetime/store/maintenance_test.exs|,
      tag: ~S|maintenance_heap_mutation|,
      test_name: ~S|recovery and forward children use heap despite caller access method|,
      assertion: ~S|assert SQL.query!|
    },
    "maintenance-transaction" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "if target.repo_module.in_transaction?() do\n      {:error, Result.failure(:in_transaction, :not_started, :open)}",
      mutated:
        "if false do\n      {:error, Result.failure(:in_transaction, :not_started, :open)}",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "maintenance_transaction_mutation",
      test_name:
        "Store maintenance refuses caller transactions before SQL and preserves their settings",
      assertion: "reason: :in_transaction"
    },
    "maintenance-caller-timeout" => %{
      path: ~S|lib/ash_onetime/store/postgres.ex|,
      original: ~S|SET LOCAL statement_timeout = #{bound}|,
      mutated: ~S|SELECT #{bound}|,
      test: ~S|test/ash_onetime/store/maintenance_test.exs|,
      tag: ~S|maintenance_timeout_mutation|,
      test_name: ~S|Store bounds real server work and rolls it back at the caller timeout|,
      assertion: ~S|reason: :maintenance_timeout|
    },
    "operation-hold-delete-guard" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original: "IF OLD.hold_reference IS NOT NULL THEN",
      mutated: "IF FALSE THEN",
      test: "test/ash_onetime/operation_hold_test.exs",
      tag: "hold_guard_mutation",
      test_name:
        "the delete guard stops a direct DELETE by the table owner before retention checks",
      assertion: "assert initial_message =~ \"held idempotency claim\""
    },
    "operation-hold-cleanup-exclusion" => %{
      path: "priv/templates/migrations/maintenance/cleanup_idempotency.sql",
      original: "AND hold_reference IS NULL",
      mutated: "AND TRUE",
      test: "test/ash_onetime/operation_hold_test.exs",
      tag: "hold_cleanup_mutation",
      test_name: "cleanup excludes held rows before the guard; the guard is not invoked",
      assertion: "assert {:ok, %{idempotency: 0}} = Store.cleanup(ctx.target, 100)"
    },
    "nonce-retention-stored-deadline" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "DateTime.compare(request.clock.now(), claim.retain_until) in [:lt, :eq]",
      mutated: "true",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_classification_mutation",
      test_name: "late replay classification follows the stored deadline including its endpoint",
      assertion: "assert {:ok, {:error, %Error{code: :invalid_nonce_window}}} = spend(replay)"
    },
    "nonce-retention-read-savepoint" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "mode = if target.repo_module.in_transaction?(), do: :savepoint, else: :transaction",
      mutated:
        "mode = if target.repo_module.in_transaction?(), do: :transaction, else: :transaction",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_read_savepoint_mutation",
      test_name: "a deadline query failure preserves caller writes and transaction usability",
      assertion: "ERROR 25P02 (in_failed_sql_transaction)"
    },
    "nonce-retention-read-dispatch" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "      {:ok, _result} -> Result.failure(:store_invariant, :not_started, :not_applicable)",
      mutated: "      {:ok, _result} -> Result.failure(:store_invariant, :sent, :not_applicable)",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_read_dispatch_mutation",
      test_name: "an unexpected deadline row has no admission dispatch",
      assertion: "assert %Result{reason: :store_invariant, admission_dispatch: :not_started}"
    },
    "nonce-retention-read-lock" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "    case dispatched_query(target, sql, Tuple.to_list(logical_key(target, request))) do",
      mutated:
        "    sql = sql <> \"\\nFOR UPDATE\"\n    case dispatched_query(target, sql, Tuple.to_list(logical_key(target, request))) do",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_read_lock_mutation",
      test_name: "late replay classification does not wait for a row lock",
      assertion: "assert {:ok, {:ok, {:error, %Error{code: :nonce_already_used}}}}"
    },
    "nonce-retention-duration" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "aggregate_verified_facts(verified_facts, retain_for || max_age, skew)",
      mutated: "aggregate_verified_facts(verified_facts, max_age, skew)",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_duration_mutation",
      test_name: "late replay remains a collision and cleanup preserves the stored deadline",
      assertion: "assert {:ok, %{nonce: 0}}"
    },
    "nonce-retention-acceptance" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "validate_verified_facts(verified_facts, evaluated_at, max_age, skew),",
      mutated:
        "validate_verified_facts(verified_facts, evaluated_at, retain_for || max_age, skew),",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_acceptance_mutation",
      test_name: "long retention never widens acceptance",
      assertion: "assert {:ok, {:error, %Error{code: :invalid_nonce_window}}}"
    },
    "nonce-retention-replay" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "        expired_nonce_result(target, request)",
      mutated: "        Result.failure(:invalid_nonce_window, :not_started, :open)",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_replay_mutation",
      test_name: "late replay remains a collision and cleanup preserves the stored deadline",
      assertion: "assert {:ok, {:error, %Error{code: :nonce_already_used}}}"
    },
    "nonce-retention-forward" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "            ] ++ Keyword.take(protection.window, [:retain_for])",
      mutated: "            ]",
      test: "test/ash_onetime/resource/nonce_retention_test.exs",
      tag: "retention_forward_mutation",
      test_name: "Ash resource retention reaches with_action claims",
      assertion: "assert deadline == Window.cleanup_after(issued, 664, 0)",
      required_failures: [
        {"Ash resource retention reaches with_action claims",
         "assert deadline == Window.cleanup_after(issued, 664, 0)"},
        {"Ash resource retention reaches independent claims",
         "assert deadline == Window.cleanup_after(issued, 664, 0)"}
      ]
    },
    "nonce-retention-legacy-skew" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "aggregate_verified_facts(verified_facts, retain_for || max_age, skew)",
      mutated: "aggregate_verified_facts(verified_facts, retain_for || max_age, 0)",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_legacy_mutation",
      test_name: "omitting retain_for preserves the exact old stored deadline",
      assertion: "assert legacy =="
    },
    "nonce-retention-upper-bound" => %{
      path: "lib/ash_onetime/window.ex",
      original: "max_age + skew <= @max_duration_seconds",
      mutated: "max_age + skew < @max_duration_seconds",
      test: "test/ash_onetime/nonce_retention_test.exs",
      tag: "retention_upper_bound_mutation",
      test_name: "the positive retention plus skew upper bound stores and reads its deadline",
      assertion: "assert {:ok, :ok} = spend(options)"
    },
    "getting-started-error-fallback" => %{
      path: "documentation/getting-started.md",
      original: "      _code -> {:error, error}",
      mutated: "      nil -> {:internal_server_error, \"unexpected error\"}",
      test: "test/ash_onetime/phoenix_documentation_test.exs",
      tag: "documentation_fallback_mutation",
      test_name: "introductory error examples handle every documented code without losing errors",
      assertion: "assert {:ok, {result, _binding}} = evaluated",
      assertion_line: 37
    },
    "errors-guide-error-fallback" => %{
      path: "documentation/errors.md",
      original: "      _code -> {:error, error}",
      mutated: "      nil -> {:internal_server_error, \"unexpected error\"}",
      test: "test/ash_onetime/phoenix_documentation_test.exs",
      tag: "documentation_fallback_mutation",
      test_name: "introductory error examples handle every documented code without losing errors",
      assertion: "assert {:ok, {result, _binding}} = evaluated",
      assertion_line: 37
    },
    "charge-recipe-error-fallback" => %{
      path: "documentation/recipes.md",
      original:
        "      :request_in_progress -> {:conflict, \"a request for this key is already processing\"}\n" <>
          "      _code -> {:error, error}",
      mutated:
        "      :request_in_progress -> {:conflict, \"a request for this key is already processing\"}\n" <>
          "      nil -> {:internal_server_error, \"unexpected error\"}",
      test: "test/ash_onetime/phoenix_documentation_test.exs",
      tag: "documentation_fallback_mutation",
      test_name: "introductory error examples handle every documented code without losing errors",
      assertion: "assert {:ok, {result, _binding}} = evaluated",
      assertion_line: 37
    },
    "redemption-recipe-error-fallback" => %{
      path: "documentation/recipes.md",
      original:
        "      :request_in_progress -> {:conflict, \"a redemption for this proof is already processing\"}\n" <>
          "      _code -> {:error, error}",
      mutated:
        "      :request_in_progress -> {:conflict, \"a redemption for this proof is already processing\"}\n" <>
          "      nil -> {:internal_server_error, \"unexpected error\"}",
      test: "test/ash_onetime/phoenix_documentation_test.exs",
      tag: "documentation_fallback_mutation",
      test_name: "introductory error examples handle every documented code without losing errors",
      assertion: "assert {:ok, {result, _binding}} = evaluated",
      assertion_line: 37
    },
    "transaction-store-rollback-propagation" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "    :throw, {DBConnection, connection_reference, _reason} = rollback\n" <>
          "    when is_reference(connection_reference) ->\n" <>
          "      throw(rollback)",
      mutated:
        "    :throw, {DBConnection, connection_reference, _reason}\n" <>
          "    when is_reference(connection_reference) ->\n" <>
          "      {:error, :invalid_nonce_window}",
      test: "test/ash_onetime/transaction_admission_test.exs",
      tag: "transaction_rollback_propagation_mutation",
      test_name: "a collaborator transaction rollback is never converted into an ordinary error",
      assertion: "assert {:error, :clock_abort}"
    },
    "transaction-boundary-rollback-propagation" => %{
      path: "lib/ash_onetime/transaction.ex",
      original: "       do: throw(rollback)",
      mutated: "       do: unavailable()",
      test: "test/ash_onetime/transaction_admission_test.exs",
      tag: "transaction_rollback_propagation_mutation",
      test_name: "a collaborator transaction rollback is never converted into an ordinary error",
      assertion: "assert {:error, :clock_abort}"
    },
    "transaction-prefix-validation" => %{
      path: "lib/ash_onetime/transaction.ex",
      original: "         :ok <- valid_prefix(prefix),",
      mutated: "         :ok <- :ok,",
      test: "test/ash_onetime/transaction_admission_test.exs",
      tag: "transaction_prefix_validation_mutation",
      test_name:
        "the public option contract rejects extras, duplicates, and malformed partitions",
      assertion: "code: :invalid_request"
    },
    "source-site-audit-proof" => %{
      path: "scripts/check_mutations.exs",
      original: "    audit_registered_" <> "sites!()",
      mutated: "    :ok",
      test: "test/mutation_check_test.exs",
      tag: "mutation_checker_source_site_mutation",
      test_name:
        "mutation checker self-test proves restoration requires an executed ExUnit result",
      assertion:
        "assert output =~ \"mutation checker self-test: every registered mutation has exactly one source site\""
    },
    "restoration-execution-proof" => %{
      path: "scripts/check_mutations.exs",
      original: "    unless executed_" <> "exunit_result?(output) do",
      mutated: "    if false do",
      test: "test/mutation_check_test.exs",
      tag: "mutation_checker_execution_proof_mutation",
      test_name:
        "mutation checker self-test proves restoration requires an executed ExUnit result",
      assertion: "assert status == 0, output",
      assertion_line: 109
    },
    "canonical" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  @integer_tag 0x02",
      mutated: "  @integer_tag 0x03",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_mutation",
      test_name: "integer encoding uses its distinct pinned domain tag",
      assertion: "assert {:ok, <<2, 0, 0, 0, 1, \"1\">>} = Canonical.encode(1)"
    },
    "canonical-vector-bytes" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "encode_scalar(@integer_tag, Integer.to_string(value), state)",
      mutated: "encode_scalar(@integer_tag, Integer.to_string(value, 16), state)",
      test: "test/ash_onetime/canonical_vectors_test.exs",
      tag: "canonical_vector_bytes_mutation",
      test_name: "every accepted vector encodes, fingerprints and decodes to its published bytes",
      assertion: "assert {name, {:ok, expected}} == {name, Canonical.encode(value)}"
    },
    "canonical-vector-bounds" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "    depth: 16,",
      mutated: "    depth: 17,",
      test: "test/ash_onetime/canonical_vectors_test.exs",
      tag: "canonical_vector_bounds_mutation",
      test_name: "every rejected vector fails with its published error",
      assertion: "assert {name, published} == {name, rejection(result)}"
    },
    "canonical-order" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "      ordered = Enum.sort_by(entries, &elem(&1, 0))",
      mutated: "      ordered = entries",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_order_mutation",
      test_name: "property map encoding follows independently sorted encoded keys",
      assertion: "assert {:ok, ^expected} = Canonical.encode(value)",
      assertion_line: 31
    },
    "canonical-surface" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  defp unsupported_error,",
      mutated:
        "  def decode(encoded), do: AshOnetime.Canonical.Decoder.decode(encoded)\n\n  defp unsupported_error,",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_surface_mutation",
      test_name: "canonical public surface does not export decoding",
      assertion: "refute function_exported?(Canonical, :decode, 1)"
    },
    "canonical-decoder-docs" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  @moduledoc false",
      mutated: "  @moduledoc \"Internal canonical decoder\"",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_decoder_docs_mutation",
      test_name: "canonical decoder module stays hidden from public documentation",
      assertion: "assert :hidden = decoder_moduledoc()"
    },
    "window" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(issued_at, oldest) in [:eq, :gt]",
      mutated: "DateTime.compare(issued_at, oldest) == :gt",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_mutation",
      test_name: "oldest replay-window endpoint is inclusive",
      assertion: "assert :ok = Window.validate(oldest, nil, @evaluated_at, 60, 5)"
    },
    "window-newest" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(issued_at, newest) in [:eq, :lt]",
      mutated: "DateTime.compare(issued_at, newest) == :lt",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_newest_mutation",
      test_name: "newest replay-window endpoint is inclusive and the next tick is invalid",
      assertion: "assert :ok = Window.validate(newest, nil, @evaluated_at, 60, 5)"
    },
    "window-expiry-order" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(expires_at, issued_at) in [:eq, :gt] and",
      mutated: "DateTime.compare(expires_at, issued_at) == :gt and",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_expiry_order_mutation",
      test_name: "an expiry equal to issuance is the inclusive ordering edge and accepts",
      assertion:
        "assert :ok = Window.validate(@evaluated_at, @evaluated_at, @evaluated_at, 60, 5)"
    },
    "window-expiry-horizon" => %{
      path: "lib/ash_onetime/window.ex",
      original: "DateTime.compare(evaluated_at, expiry_horizon) in [:eq, :lt]",
      mutated: "DateTime.compare(evaluated_at, expiry_horizon) == :lt",
      test: "test/ash_onetime/window_test.exs",
      tag: "window_expiry_horizon_mutation",
      test_name: "expiry is ordered and inclusive through skew",
      assertion: "assert :ok = Window.validate(issued_at, expires_at, @evaluated_at, 60, 5)"
    },
    "classifier-context-guard" => %{
      path: "lib/ash_onetime/response_classifier.ex",
      original:
        "def classify(classifier, value, context) when is_atom(classifier) and is_map(context) do",
      mutated: "def classify(classifier, value, context) when is_atom(classifier) do",
      test: "test/ash_onetime/response_classifier_test.exs",
      tag: "classifier_context_guard_mutation",
      test_name: "a non-map context fails closed before the classifier is invoked",
      assertion: "ResponseClassifier.classify(StoreClassifier, :secret, :not_a_map)"
    },
    "cache-fingerprint-conjunct" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "fixed_equal?(entry.fingerprint, claim.fingerprint)",
      mutated: "is_binary(entry.fingerprint)",
      test: "test/ash_onetime/cache_test.exs",
      tag: "cache_fingerprint_conjunct_mutation",
      test_name:
        "valid_entry? conjunct isolation and admission authority (unit) an entry whose fingerprint mismatches the claim degrades to stale",
      assertion: "assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)",
      assertion_line: 100
    },
    "cache-codec-conjunct" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "entry.codec == claim.response_codec",
      mutated: "is_binary(entry.codec)",
      test: "test/ash_onetime/cache_test.exs",
      tag: "cache_codec_conjunct_mutation",
      test_name:
        "valid_entry? conjunct isolation and admission authority (unit) an entry whose codec mismatches the claim degrades to stale",
      assertion: "assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)",
      assertion_line: 107
    },
    "cache-digest-conjunct" => %{
      path: "lib/ash_onetime/cache.ex",
      original: "fixed_equal?(entry.digest, claim.response_digest)",
      mutated: "is_binary(entry.digest)",
      test: "test/ash_onetime/cache_test.exs",
      tag: "cache_digest_conjunct_mutation",
      test_name:
        "valid_entry? conjunct isolation and admission authority (unit) an entry whose digest field mismatches the claim degrades to stale",
      assertion: "assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)",
      assertion_line: 116
    },
    "locked-external-claim-class" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "  defp execution_class(:idempotency, :locked_external_claim), do: :external_execute\n",
      mutated: "",
      test: "test/ash_onetime/admission_test.exs",
      tag: "locked_external_claim_class_mutation",
      test_name:
        "resolve/5: the :admitted arm idempotency locked external claim maps to :external_execute under an open transaction",
      assertion: "Admission.resolve(",
      assertion_line: 305
    },
    "ets-cap-serialized-put" => %{
      path: "lib/ash_onetime/cache/ets.ex",
      original: "GenServer.call(@table, {:put, key, entry, ttl_seconds})",
      mutated:
        "maybe_evict(max_entries()); :ets.insert(@table, {key, entry, System.monotonic_time(:second) + ttl_seconds}); :ok",
      test: "test/ash_onetime/cache/ets_test.exs",
      tag: "ets_cap_serialized_mutation",
      test_name:
        "the cap under concurrent writers concurrent puts never leave more entries than the cap",
      assertion: "assert entry_count() == 1",
      assertion_line: 119
    },
    "cleanup-partition-limit-guard" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "partition_limit <= @max_partition_drops do",
      mutated: "partition_limit <= 999_999 do",
      test: "test/ash_onetime/store/cleanup_test.exs",
      tag: "cleanup_partition_limit_guard_mutation",
      test_name: "cleanup rejects out-of-range batch sizes and partition limits",
      assertion: "} = Store.cleanup(target, 100, 129)"
    },
    "resource-relationship-leak" => %{
      path: "lib/ash_onetime/codec/resource.ex",
      original: "&relationship_unloaded?(value, &1, resource)",
      mutated: "fn _relationship -> true end",
      test: "test/ash_onetime/codec/resource_test.exs",
      tag: "resource_relationship_leak_mutation",
      test_name: "encode rejects a result carrying a loaded relationship",
      assertion:
        "assert {:error, %Error{code: :response_value_invalid}} = Resource.encode(loaded, contract, [])"
    },
    "scope-component-limit" => %{
      path: "lib/ash_onetime/scope.ex",
      original: "length(components) > @max_components ->",
      mutated: "length(components) > 999_999 ->",
      test: "test/ash_onetime/scope_test.exs",
      tag: "scope_component_limit_mutation",
      test_name:
        "normalize/1 fails closed on every malformed scope rejects one component over the limit",
      assertion: "assert {:error, message} = Scope.normalize(over)",
      assertion_line: 37
    },
    "scope-uniqueness" => %{
      path: "lib/ash_onetime/scope.ex",
      original: "Enum.uniq(components) != components ->",
      mutated: "false ->",
      test: "test/ash_onetime/scope_test.exs",
      tag: "scope_uniqueness_mutation",
      test_name: "normalize/1 fails closed on every malformed scope rejects duplicate components",
      assertion: "Scope.normalize(static: \"x\", attribute: :a, static: \"x\")",
      assertion_line: 43
    },
    "ed25519-verify-honored" => %{
      path: "lib/ash_onetime/signer/ed25519.ex",
      original: "if :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519]) do",
      mutated: "if true do",
      test: "test/ash_onetime/signer/ed25519_test.exs",
      tag: "ed25519_wrong_key_mutation",
      test_name: "a valid signature is invalid under a different, equally valid public key",
      assertion: "Ed25519.verify(\"bound to key A\", signature, public(public_b))"
    },
    "canonical-decoder-order" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "is_nil(previous) or key_raw > previous ->",
      mutated: "is_nil(previous) or is_binary(key_raw) ->",
      test: "test/ash_onetime/canonical_test.exs",
      tag: "canonical_decoder_identity_mutation",
      test_name: "decoder rejects trailing, duplicate, and noncanonical map bytes",
      assertion: "Decoder.decode(reversed)"
    },
    "token-from-body-bounds" => %{
      path: "lib/ash_onetime/token.ex",
      original: ":ok <- validate_identifier(body[\"key_id\"], :invalid_key_id, :key_id),",
      mutated: ":ok <- :ok,",
      test: "test/ash_onetime/token_test.exs",
      tag: "token_from_body_bounds_mutation",
      test_name: "verify re-validates the decoded body's key_id bound before the signature",
      assertion: "Token.verify(encoded, Local, verify_options())"
    },
    "secure-equal-length" => %{
      path: "lib/ash_onetime/signer/hmac.ex",
      original:
        "_exception -> {:error, Error.new(:invalid_signature, \"HMAC signature is invalid\")}",
      mutated: "_exception -> :ok",
      test: "test/ash_onetime/signer/hmac_test.exs",
      tag: "secure_equal_length_mutation",
      test_name: "invalid trusted keys and signature sizes fail closed",
      assertion: "HMAC.verify(\"message\", <<0>>, same_service(@rfc_key))"
    },
    "token-identifier-bound" => %{
      path: "lib/ash_onetime/token.ex",
      original: "  @max_identifier_bytes 128",
      mutated: "  @max_identifier_bytes 10_000",
      test: "test/ash_onetime/token_test.exs",
      tag: "token_identifier_bound_mutation",
      test_name: "token identifier limits accept exact edges and reject first excess",
      assertion: "assert {:error, %Error{code: :invalid_key_id}} ="
    },
    "hmac-key-bound" => %{
      path: "lib/ash_onetime/signer/hmac.ex",
      original: "  @max_key_bytes 4_096",
      mutated: "  @max_key_bytes 10_000",
      test: "test/ash_onetime/signer/hmac_test.exs",
      tag: "hmac_key_bound_mutation",
      test_name: "trusted key bytes accept the exact limit and reject the first excess",
      assertion: "assert {:error, %Error{code: :invalid_key}} = HMAC.sign"
    },
    "signature" => %{
      path: "lib/ash_onetime/token.ex",
      original: "{:ok, signature} <- custody_sign(custody, token, body_bytes, custody_context),",
      mutated:
        "{:ok, signature} <- custody_sign(custody, token, (case body_bytes do <<first, rest::binary>> -> <<Bitwise.bxor(first, 1), rest::binary>> end), custody_context),",
      test: "test/ash_onetime/token_test.exs",
      tag: "signature_mutation",
      test_name: "signature binds the exact canonical body bytes",
      assertion: "assert {:ok, ^token} = Token.verify(encoded, Local, verify_options())"
    },
    "dsl-idempotency" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_idempotency(protection, context),\n    do: verify_idempotency_details(protection, context)",
      mutated: "  defp verify_idempotency(protection, _context), do: {:ok, protection}",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_idempotency_mutation",
      test_name: "idempotency requires replay contracts",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"excessive_bounds.exs", "AshOnetime.CompileFixtures.ExcessiveBounds"}
    },
    "dsl-nonce" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_nonce(protection, context), do: verify_nonce_details(protection, context)",
      mutated: "  defp verify_nonce(protection, _context), do: {:ok, protection}",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_nonce_mutation",
      test_name: "nonce rejects replay response configuration",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"nonce_response.exs", "AshOnetime.CompileFixtures.NonceResponse"}
    },
    "dsl-nonce-key" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_nonce_key(protection, context), do: verify_nonce_key_details(protection, context)",
      mutated: "  defp verify_nonce_key(_protection, _context), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_nonce_key_mutation",
      test_name: "nonce requires trusted key sources",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unverified_nonce_key.exs", "AshOnetime.CompileFixtures.UnverifiedNonceKey"}
    },
    "dsl-lifecycle" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_lifecycle(protection, context), do: verify_lifecycle_details(protection, context)",
      mutated: "  defp verify_lifecycle(_protection, _context), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_lifecycle_mutation",
      test_name: "idempotency rejects replay-unsafe lifecycle callbacks",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unsafe_hook.exs", "AshOnetime.CompileFixtures.UnsafeHook"}
    },
    "dsl-duplicate" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp reject_duplicates(protections, dsl_state),\n    do: reject_duplicate_details(protections, dsl_state)",
      mutated: "  defp reject_duplicates(_protections, _dsl_state), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_duplicate_mutation",
      test_name: "duplicate protection is transformer-owned",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"duplicate_protection.exs", "AshOnetime.CompileFixtures.DuplicateProtection"}
    },
    "dsl-references" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_references(references, protection, context, option),\n    do: verify_reference_details(references, protection, context, option)",
      mutated: "  defp verify_references(_references, _protection, _context, _option), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_references_mutation",
      test_name: "key sources must reference declared action inputs",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"missing_key_reference.exs", "AshOnetime.CompileFixtures.MissingKeyReference"}
    },
    "dsl-builtin-options" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_replay_ref(ref, allowlist), do: verify_replay_ref_details(ref, allowlist)",
      mutated: "  defp verify_replay_ref(_ref, _allowlist), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_builtin_options_mutation",
      test_name: "replay-safe built-ins require literal options",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unsafe_builtin_option.exs", "AshOnetime.CompileFixtures.UnsafeBuiltinOption"}
    },
    "dsl-validations" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_replay_validation(validation), do: verify_replay_validation_details(validation)",
      mutated: "  defp verify_replay_validation(_validation), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_validations_mutation",
      test_name: "idempotency rejects replay-unsafe validations",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"unsafe_validation.exs", "AshOnetime.CompileFixtures.UnsafeValidation"}
    },
    "dsl-attribute-tenant-scope" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "  defp verify_tenant_scope(scope, protection, context),\n    do: verify_tenant_scope_details(scope, protection, context)",
      mutated: "  defp verify_tenant_scope(_scope, _protection, _context), do: :ok",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_attribute_tenant_scope_mutation",
      test_name: "attribute multitenancy requires the tenant discriminator in scope",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe:
        {"attribute_multitenant_unscoped.exs",
         "AshOnetime.CompileFixtures.AttributeMultitenantUnscoped"}
    },
    "dsl-attribute-tenant-scope-equality" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "not is_nil(tenant_attribute) and attribute == tenant_attribute",
      mutated: "not is_nil(tenant_attribute) and is_atom(attribute)",
      test: "test/compile_fixtures_test.exs",
      tag: "dsl_attribute_tenant_scope_equality_mutation",
      test_name: "attribute multitenancy rejects a non-tenant attribute in scope",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe:
        {"attribute_multitenant_wrong_attribute.exs",
         "AshOnetime.CompileFixtures.AttributeMultitenantWrongAttribute"}
    },
    "dsl-response-unknown-opt" => %{
      path: "lib/ash_onetime/resource.ex",
      original:
        "      fields: [\n        type: {:list, :atom},\n        default: [],\n        doc:\n          \"The resource attributes projected into the stored/replayed response payload. \" <>\n            \"Acts as the field allowlist; attributes not named here never enter the response.\"\n      ],",
      mutated:
        "      field: [\n        type: {:list, :atom},\n        default: [],\n        doc: \"mutant alias that accepts the typo the guard rejects.\"\n      ],\n      fields: [\n        type: {:list, :atom},\n        default: [],\n        doc:\n          \"The resource attributes projected into the stored/replayed response payload. \" <>\n            \"Acts as the field allowlist; attributes not named here never enter the response.\"\n      ],",
      test: "test/compile_fixtures_test.exs",
      tag: "response_unknown_opt_mutation",
      test_name: "response rejects unknown options (no silent drop)",
      assertion: "ASH_ONETIME_FIXTURE_RESULT=compiled",
      probe: {"response_unknown_opt.exs", "AshOnetime.CompileFixtures.ResponseUnknownOpt"}
    },
    "response-limits-unknown-key" => %{
      path: "lib/ash_onetime/response.ex",
      original:
        "    if typos == [],\n      do: {:ok, selected},\n      else: {:error, :unknown, Enum.map(typos, &elem(&1, 0))}",
      mutated: "    {:ok, selected}",
      test: "test/ash_onetime/codec/response_test.exs",
      tag: "response_limits_unknown_key_mutation",
      test_name: "response limits reject unknown option keys (no silent drop)",
      assertion: "{:error, %Error{code: :response_contract_invalid}}"
    },
    "structural-limits-map-take" => %{
      path: "lib/ash_onetime/codec.ex",
      original:
        "    Map.merge(known, Map.take(Map.get(contract, :limits, %{}), Map.keys(known)))",
      mutated: "    Map.merge(known, Map.get(contract, :limits, %{}))",
      test: "test/ash_onetime/codec/resource_test.exs",
      tag: "structural_limits_map_take_mutation",
      test_name: "structural_limits ignores non-response keys even on an un-normalized contract",
      assertion: "refute Map.has_key?(structural, :max_key_bytes)"
    },
    "unique-constraint" => %{
      tag: "unique_constraint_mutation",
      path: "lib/mix/tasks/ash_onetime.gen.migrations.ex",
      original:
        "@collision_constraint \"UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)\"",
      test: "test/system/contention_test.exs",
      test_name: "a contended real action commits one append-only effect",
      assertion: "assert first_result.id == second_result.id",
      mutated: "@collision_constraint \"CONSTRAINT mutation_collision_disabled CHECK (true)\""
    },
    "boundary-check-predicate" => %{
      path: "lib/ash_onetime/boundary.ex",
      original: ~S|WHERE tenant = $1 AND seq > $2 AND #{predicate}|,
      mutated: ~S|WHERE tenant = $1 AND seq > $2 + 1000000000 AND #{predicate}|,
      test: "test/ash_onetime/boundary_contention_test.exs",
      tag: "boundary_check_mutation",
      test_name: "overlapping contexts admit exactly one append per read epoch",
      assertion: "assert admitted == 1"
    },
    "rls-prune-unforce" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "EXECUTE format('ALTER TABLE %s NO FORCE ROW LEVEL SECURITY',child_name);",
      mutated: "PERFORM 1;",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_unforce_mutation",
      test_name:
        "tenant-session cleanup under FORCE RLS drops the empty partition, keeps the occupied one, and still deletes claims",
      assertion: "assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} = result"
    },
    "rls-isolation-precondition" => %{
      path: "priv/templates/migrations/maintenance/lock.sql",
      original: "IF current_setting('transaction_isolation') <> 'read committed' THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "maintenance_isolation_mutation",
      test_name: "SQL rejects NULL and out of range bounds and repeatable read",
      assertion: "pg_code: \"25001\""
    },
    "rls-partition-kept" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "IF occupied THEN RAISE EXCEPTION 'occupied' USING ERRCODE='AOP01'; END IF;",
      mutated: "IF occupied THEN kept := kept+1; CONTINUE; END IF;",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_partition_kept_mutation",
      test_name:
        "tenant-session cleanup under FORCE RLS drops the empty partition, keeps the occupied one, and still deletes claims",
      # Keeping the occupied child without raising skips the subtransaction rollback that
      # restores FORCE; the counts are unchanged, so only the FORCE flag can see it.
      assertion: "assert force_flagged?(prefix, partition)"
    },
    "rls-child-policy-copy" => %{
      path: "priv/templates/migrations/maintenance/copy_policy.sql",
      original:
        "WHERE p.polrelid=format('%I.%I', @schema_name@, 'ash_onetime_response_payloads')::regclass",
      mutated: "WHERE p.polrelid=0",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "rls_child_policy_copy_mutation",
      test_name: "forward roll copies policies and flags and resets table and column ACLs",
      assertion: "policy_sql"
    },
    "boundary-lock-noop" => %{
      path: "lib/ash_onetime/boundary.ex",
      original: ~S|"SELECT pg_advisory_xact_lock(hashtext($1::text), hashtext($2::text))"|,
      mutated: ~S|"SELECT $1::text, $2::text"|,
      test: "test/ash_onetime/boundary_contention_test.exs",
      tag: "boundary_check_mutation",
      test_name: "overlapping contexts admit exactly one append per read epoch",
      assertion: "assert admitted == 1"
    },
    "cleanup-boundary" => %{
      path: "priv/templates/migrations/maintenance/eligible.sql",
      original: "transaction_timestamp() > retain_until",
      mutated: "transaction_timestamp() >= retain_until",
      test: "test/system/window_cleanup_test.exs",
      tag: "cleanup_strictness_mutation",
      test_name:
        "cleanup preserves the inclusive replay horizon then removes the first expired instant",
      assertion: "assert %{rows: [[false]]} ="
    },
    "reap-removes-abandoned" => %{
      path: "priv/templates/migrations/maintenance/reap.sql",
      original: "AND inserted_at < reap_before",
      mutated: "AND false",
      test: "test/ash_onetime/store/reap_test.exs",
      tag: "reap_removes_abandoned_mutation",
      test_name:
        "reaps a processing recovery point past the abandonment horizon and its retention",
      assertion: "assert {:ok, 1} = Store.reap(target, 100, @horizon)"
    },
    "reap-retention-guard" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original: "OR NOT (transaction_timestamp() > OLD.retain_until) THEN",
      mutated: "OR false THEN",
      test: "test/ash_onetime/store/reap_test.exs",
      tag: "reap_retention_guard_mutation",
      test_name: "never reaps a processing claim still inside its retention horizon",
      assertion: "assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ="
    },
    "reap-floor-guard" => %{
      path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
      original: "OR OLD.inserted_at >= transaction_timestamp() - interval '86400 seconds'",
      mutated: "OR false",
      test: "test/ash_onetime/store/reap_test.exs",
      tag: "reap_floor_guard_mutation",
      test_name: "never reaps a processing claim younger than the hard floor",
      assertion: "assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ="
    },
    "reap-skips-locked-recovery" => %{
      path: "priv/templates/migrations/maintenance/reap.sql",
      original: "FOR UPDATE SKIP LOCKED LIMIT batch_size",
      mutated: "FOR UPDATE LIMIT batch_size",
      test: "test/ash_onetime/store/reap_contention_test.exs",
      tag: "reap_skips_locked_recovery_mutation",
      test_name: "the reaper skips a recovery point locked by an in-flight finalization",
      assertion: "assert_receive {:reaper_done, ^reaper, {:ok, 0}}"
    },
    "payload-partition" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "transaction_timestamp()::date <= bounds[2]::date",
      mutated: "transaction_timestamp()::date < bounds[2]::date",
      test: "test/mix/tasks/ash_onetime.prune_test.exs",
      tag: "payload_partition_mutation",
      test_name:
        "manual cleanup retains the exact database-date boundary and drops only older empty partitions",
      assertion: "payload_partitions: 1"
    },
    "partitions-created-telemetry" => %{
      path: "lib/ash_onetime/telemetry.ex",
      original:
        "cleanup: [\n      :responses_expired,\n      :claims_deleted,\n      :partitions_dropped,\n      :partitions_created,\n      :partitions_kept\n    ]",
      mutated:
        "cleanup: [\n      :responses_expired,\n      :claims_deleted,\n      :partitions_dropped,\n      :partitions_kept\n    ]",
      test: "test/ash_onetime/store/partition_test.exs",
      tag: "partitions_created_telemetry_mutation",
      test_name:
        "roll_partitions/2 (SEC-5 forward partition creation) emits a :cleanup :partitions_created telemetry event on a roll",
      assertion: ":partitions_created",
      assertion_line: 142
    },
    "rls-error-to-kept" => %{
      tag: "rls_error_to_kept_mutation",
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "WHEN OTHERS THEN reason := 'ddl_blocked';",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      test_name:
        "owner-driven prune an event trigger blocking ALTER TABLE keeps partitions and fails nothing",
      assertion: "(raise_exception) DDL blocked",
      mutated: "WHEN OTHERS THEN RAISE;",
      assertion_line: 1142
    },
    "payload-partition-count" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s)',child_name) INTO occupied;",
      mutated: "occupied := false;",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_count_mutation",
      test_name:
        "tenant-session cleanup under FORCE RLS drops the empty partition, keeps the occupied one, and still deletes claims",
      assertion: "assert {:ok, %{payload_partitions: 1, payload_partitions_kept: 1}} = result"
    },
    "rls-prune-force-gate" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=candidate.oid) THEN",
      mutated: "IF false THEN",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_force_gate_mutation",
      test_name:
        "owner-driven prune a DDL hook reapplying FORCE is refused explicitly and preserves hidden payloads",
      assertion: "assert {:ok, %{payload_partitions_refused: %{force_reapplied: 2}}} = result",
      assertion_line: 622
    },
    "rls-prune-row-security" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "PERFORM set_config('row_security','off',true);",
      mutated: "PERFORM set_config('row_security','on',true);",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_guc_mutation",
      test_name:
        "owner-driven prune row_security is off before NO FORCE and both caller GUCs are restored",
      assertion: "assert {:ok, %{payload_partitions: 2}} =",
      assertion_line: 654
    },
    "rls-prune-parent-lock" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original:
        "LOCK TABLE ONLY @schema@.ash_onetime_response_payloads IN ACCESS EXCLUSIVE MODE;",
      mutated:
        "LOCK TABLE ONLY @schema@.ash_onetime_response_payloads IN SHARE UPDATE EXCLUSIVE MODE;",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_lock_mutation",
      test_name:
        "owner-driven prune a parent reader bounds prune and insert waits without a child lock deadlock",
      assertion: "assert child_locks == 0",
      assertion_line: 743
    },
    "rls-prune-lock-timeout" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "PERFORM set_config('lock_timeout',remaining::text,true);",
      mutated: "PERFORM 1;",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_lock_mutation",
      test_name:
        "owner-driven prune a parent reader bounds prune and insert waits without a child lock deadlock",
      assertion: "Task.await(prune_task, 4_000)",
      assertion_line: 762
    },
    "rls-prune-pass-budget" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original:
        "remaining := floor(extract(epoch FROM (deadline-clock_timestamp()))*1000)::integer;",
      mutated: "remaining := lock_budget_ms;",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_budget_mutation",
      test_name:
        "owner-driven prune the budget spans acquisitions: a second holder gets only what remains",
      assertion: "assert finished_at - waiting_started < 3700",
      assertion_line: 862
    },
    "rls-prune-single-pruner" => %{
      tag: "rls_prune_single_pruner_mutation",
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "IF NOT pg_try_advisory_xact_lock(1095716946,parent_oid::integer) THEN",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      test_name:
        "owner-driven prune overlapping cleanups on one payload parent neither deadlock nor double-prune",
      assertion: "assert Enum.all?(results",
      mutated: "IF false THEN",
      assertion_line: 910
    },
    "prune-child-nowait" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE NOWAIT',child_name",
      mutated: "LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE',child_name",
      test: "test/mix/tasks/ash_onetime.prune_test.exs",
      tag: "payload_partition_lock_mutation",
      test_name:
        "a child held by a direct reader is skipped without waiting and its sibling still drops",
      assertion: "payload_partitions: 1"
    },
    "prune-default-nowait" => %{
      path: "priv/templates/migrations/maintenance/prune.sql",
      original: "LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE NOWAIT',default_oid::regclass",
      mutated: "LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE',default_oid::regclass",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_default_mutation",
      test_name:
        "owner-driven prune a DEFAULT-only holder is refused without waiting while the parent is held",
      assertion: "payload_partitions_refused: %{lock_unavailable: 2}",
      assertion_line: 820
    },
    "rls-prune-catalog-count" => %{
      path: "priv/templates/migrations/maintenance/settings.sql",
      original: "SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD'\n",
      mutated: "SET DateStyle = 'ISO, YMD'\n",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "maintenance_functions_mutation",
      test_name: "all maintenance entry points are owner definers with a fixed search path",
      assertion: "search_path=pg_catalog, pg_temp"
    },
    "routine-lock-timeout-scope" => %{
      path: "priv/templates/migrations/maintenance/settings.sql",
      original: "SET row_security = on SET lock_timeout = '5s'",
      mutated: "SET row_security = on",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "routine_lock_scope_mutation",
      test_name:
        "routines pin DateStyle, row security and lock_timeout and restore the caller's settings",
      assertion: ~S|assert scalar(c.runtime_repo, "SHOW #{setting}") == value|
    },
    "routine-lock-timeout-catalog" => %{
      path: "priv/templates/migrations/maintenance/settings.sql",
      original: "SET row_security = on SET lock_timeout = '5s'",
      mutated: "SET row_security = on SET lock_timeout = '7s'",
      test: "test/ash_onetime/store/maintenance_test.exs",
      tag: "routine_lock_catalog_mutation",
      test_name: "top-level routines pin lock_timeout and statement helpers inherit it",
      assertion: "assert \"lock_timeout=5s\" in settings"
    },
    "rls-prune-refusal-telemetry" => %{
      tag: "rls_prune_refusal_telemetry_mutation",
      path: "lib/ash_onetime/store.ex",
      original: "if refused > 0 do",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      test_name:
        "owner-driven prune occupied partitions emit no refusal event and a non-owner reports refusals",
      assertion: "refute_receive {:cleanup_event, _, %{result_class: :partitions_kept}}",
      mutated: "if counts.payload_partitions_kept > 0 do",
      assertion_line: 990
    },
    "rls-prune-foreign-child" => %{
      path: "priv/templates/migrations/maintenance/trust.sql",
      original: "WHERE true -- R1 relation set",
      mutated: "WHERE false -- R1 relation set",
      test: "test/ash_onetime/store/rls_prune_test.exs",
      tag: "rls_prune_foreign_child_mutation",
      test_name:
        "owner-driven prune a real foreign child is refused before its remote RLS-filtered count",
      assertion: "untrusted_dependency",
      assertion_line: 524
    },
    "doctor-ash-floor" => %{
      path: "lib/mix/tasks/ash_onetime.doctor.ex",
      original: "@ash_floor Version.parse!(\"3.37.2\")",
      mutated: "@ash_floor Version.parse!(\"3.37.1\")",
      test: "test/mix/tasks/ash_onetime.doctor_test.exs",
      tag: "doctor_ash_floor_mutation",
      test_name:
        "ash floor verdict (pure seam) rejects the Ash release preceding the patched multitenant-upsert floor",
      assertion: "assert {:fail, message} = Doctor.floor_status(Version.parse!(\"3.37.1\"))",
      assertion_line: 66
    },
    "mixpin-ash-floor" => %{
      path: "mix.exs",
      original: "@ash_floor \"3.37.2\"",
      mutated: "@ash_floor \"3.37.1\"",
      test: "test/mix/ash_pin_validation_test.exs",
      tag: "mixpin_ash_floor_mutation",
      test_name: "rejects a below-floor pin at config evaluation",
      assertion: "assert exit != 0"
    },
    "deps-ash-postgres-floor" => %{
      path: "mix.exs",
      original: "{:ash_postgres, \"~> 2.15 and >= 2.15.2\"}",
      mutated: "{:ash_postgres, \"~> 2.15 and >= 2.15.1\"}",
      test: "test/mix/dependency_security_test.exs",
      tag: "deps_ash_postgres_floor_mutation",
      test_name: "ash_postgres consumer requirement rejects advised versions",
      assertion: "refute Version.match?(\"2.15.1\", requirement)"
    },
    "deps-ash-sql-floor" => %{
      path: "mix.exs",
      original: "{:ash_sql, \"~> 0.8 and >= 0.8.6\", runtime: false}",
      mutated: "{:ash_sql, \"~> 0.8 and >= 0.8.5\", runtime: false}",
      test: "test/mix/dependency_security_test.exs",
      tag: "deps_ash_sql_floor_mutation",
      test_name: "ash_sql consumer requirement rejects advised versions",
      assertion: "refute Version.match?(\"0.8.5\", requirement)"
    },
    "deps-mint-floor" => %{
      path: "mix.exs",
      original: "{:mint, \"~> 1.10 and >= 1.10.2\", optional: true, runtime: false}",
      mutated: "{:mint, \"~> 1.10 and >= 1.10.1\", optional: true, runtime: false}",
      test: "test/mix/dependency_security_test.exs",
      tag: "deps_mint_floor_mutation",
      test_name: "mint consumer requirement rejects advised versions",
      assertion: "refute Version.match?(\"1.10.1\", requirement)"
    },
    "deps-igniter-floor" => %{
      path: "mix.exs",
      original: "{:igniter, \"~> 0.8 and >= 0.8.4\", optional: true, runtime: false}",
      mutated: "{:igniter, \"~> 0.8\", optional: true, runtime: false}",
      test: "test/mix/dependency_security_test.exs",
      tag: "deps_igniter_floor_mutation",
      test_name: "igniter consumer requirement rejects advised versions",
      assertion: "refute Version.match?(\"0.8.3\", requirement)"
    },
    "deps-optional-runtime" => %{
      path: "mix.exs",
      original: "{:igniter, \"~> 0.8 and >= 0.8.4\", optional: true, runtime: false}",
      mutated: "{:igniter, \"~> 0.8 and >= 0.8.4\", optional: true}",
      test: "test/mix/dependency_security_test.exs",
      tag: "deps_optional_runtime_mutation",
      test_name: "security constraints preserve host-owned optional runtime applications",
      assertion: "assert options[:runtime] == false"
    },
    "operation-hash-select" => %{
      tag: "operation_hash_select_mutation",
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "@logical_key_predicate \"logical_partition = $1 AND operation_hash = $2 AND scope_hash = $3 AND key_hash = $4\"",
      test: "test/ash_onetime/store/uncertainty_test.exs",
      test_name: "nonce replay and deadline reads preserve operation identity",
      assertion: "assert {:ok, deadline}",
      mutated:
        "@logical_key_predicate \"logical_partition = $1 AND $2::bytea IS NOT NULL AND operation_hash = operation_hash AND scope_hash = $3 AND key_hash = $4\"",
      assertion_line: 155
    },
    "operation-hash-completion" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "@completion_key_predicate \"logical_partition = $4 AND operation_hash = $5 AND scope_hash = $6 AND key_hash = $7\"",
      mutated:
        "@completion_key_predicate \"logical_partition = $4 AND $5::bytea IS NOT NULL AND operation_hash = operation_hash AND scope_hash = $6 AND key_hash = $7\"",
      test: "test/ash_onetime/store/partition_test.exs",
      tag: "operation_hash_completion_mutation",
      test_name: "completion update keeps operation identity when hash partitions share an id",
      assertion: "assert {:ok, %Result{status: :complete, claim: complete}}"
    },
    "operation-hash-cleanup" => %{
      path: "priv/templates/migrations/maintenance/cleanup_idempotency.sql",
      original: "AND claims.operation_hash=candidates.operation_hash AND claims.id=candidates.id",
      mutated:
        "AND candidates.operation_hash=candidates.operation_hash AND claims.id=candidates.id",
      test: "test/ash_onetime/store/partition_test.exs",
      tag: "operation_hash_cleanup_mutation",
      test_name: "cleanup delete keeps operation identity when hash partitions share an id",
      assertion: "assert {:ok, %{idempotency: 1, nonce: 0}}"
    },
    "response-field-guard" => %{
      path: "lib/ash_onetime/codec/resource.ex",
      original: "    MapSet.new(actual) == MapSet.new(Enum.map(expected, &Atom.to_string/1))",
      mutated: "    true",
      test: "test/ash_onetime/codec/resource_test.exs",
      tag: "response_allowlist_mutation",
      test_name: "undeclared sentinel private payload field is terminal",
      assertion: "assert {:error, %Error{code: :response_fields_invalid}} ="
    },
    "return-contract" => %{
      path: "test/support/resources/result_examples.ex",
      original: "    action :nullable_result, :string do",
      mutated: "    action :nullable_result, :uuid do",
      test: "test/ash_onetime/codec/response_test.exs",
      tag: "return_type_mutation",
      test_name: "fixed bytes bind the live return contract before custom decode",
      assertion: "assert {:ok, \"fixed\"} = Response.replay(store_result(fixed), contract, [])"
    },
    "replay-execution" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "when class in [:execute, :external_execute, :nonce, :untracked] ->",
      mutated: "when class in [:execute, :external_execute, :nonce, :untracked, :replay] ->",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "replay_execution_mutation",
      test_name: "generic original runs once and its typed stored result replays",
      assertion: "refute_receive {:generic_run, _arguments}",
      assertion_line: 304
    },
    "corrupt-replay-execution" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "{:error, %Error{} = error} ->\n        emit_conflict(state, :malformed)\n        {:error, error}",
      mutated:
        "{:error, %Error{} = _error} ->\n        {:execute, %{state | class: :execute, claim: result.claim}}",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "corrupt_replay_mutation",
      test_name: "corrupt authoritative replay is terminal and never repairs by executing again",
      assertion: "assert_terminal_replay(prefix, input)",
      assertion_line: 522
    },
    "completion" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "case AshOnetime.Admission.complete(state, persisted_result) do",
      mutated: "case {:ok, persisted_result} do",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_mutation",
      test_name: "completion failure rolls back a generic effect through the real wrapper",
      assertion: "assert {:error, _error} ="
    },
    "crud-result-tuple" => %{
      path: "lib/ash_onetime/change.ex",
      original: "|> Ash.Changeset.set_result({:ok, decoded})",
      mutated: "|> Ash.Changeset.set_result(decoded)",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "crud_tuple_mutation",
      test_name:
        "CRUD execution, claim, response completion, and replay share one tenant transaction",
      assertion: "|> Ash.create()",
      assertion_line: 214
    },
    "crud-completion" => %{
      path: "lib/ash_onetime/change.ex",
      original: "case AshOnetime.Admission.complete(state, result) do",
      mutated: "case {:ok, result} do",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "crud_tuple_mutation",
      test_name:
        "CRUD execution, claim, response completion, and replay share one tenant transaction",
      assertion: "assert {:ok, replayed} ="
    },
    "atomic-error-form" => %{
      path: "lib/ash_onetime/change.ex",
      original: "do: {:not_atomic, \"keyed effects require transactional stream execution\"}",
      mutated: "do: {:error, \"keyed effects require transactional stream execution\"}",
      test: "test/ash_onetime/change_test.exs",
      tag: "atomic_shape_mutation",
      test_name: "protected changes force transactional stream execution",
      assertion:
        "assert {:not_atomic, \"keyed effects require transactional stream execution\"} ="
    },
    "bulk-fallback" => %{
      path: "lib/ash_onetime/change.ex",
      original: "Enum.map(changesets, &change(&1, opts, context))",
      mutated: "changesets",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "bulk_fallback_mutation",
      test_name: "protected bulk create falls back to transactional stream execution",
      assertion: "assert table_count(prefix, \"ash_onetime_idempotency_claims\") == 2"
    },
    "state-request-sanitization" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "request: sanitize_request(state.request)},\n        protection,\n        started,\n        :local_claim",
      mutated:
        "request: state.request},\n        protection,\n        started,\n        :local_claim",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "state_confidentiality_mutation",
      test_name: "verified nonce admits one generic execution then rejects reuse",
      assertion: "refute state_bytes =~ \"nonce-proof\""
    },
    "state-claim-sanitization" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "class: class, claim: sanitize_claim(result.claim)",
      mutated: "class: class, claim: result.claim",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "state_confidentiality_mutation",
      test_name: "verified nonce admits one generic execution then rejects reuse",
      # The unsanitized claim leaks its verifier_id ("action-verifier") into the serialized
      # admission state, so the state_bytes refute fires before the later verifier_id assertion.
      assertion: "refute state_bytes =~ \"action-verifier\""
    },
    "completion-codec" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "true <- claim.response_codec == encoded.codec,",
      mutated: "true <- is_binary(claim.response_codec),",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "completion-payload" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "true <- payload == encoded.payload,\n         true <- fixed_digest_equal?(claim.response_digest, encoded.digest),\n         true <- fixed_digest_equal?(:crypto.hash(:sha256, payload), encoded.digest)",
      mutated:
        "true <- is_binary(payload),\n         true <- fixed_digest_equal?(claim.response_digest, encoded.digest),\n         true <- true",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "completion-digest" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "true <- fixed_digest_equal?(claim.response_digest, encoded.digest),",
      mutated: "true <- is_binary(claim.response_digest),",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "completion-partition" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "response_partition: %Date{},",
      mutated: "response_partition: _response_partition,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "completion-partition-clock" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":ok <- validate_claim_state(claim, :complete),",
      mutated:
        ":ok <- validate_claim_state(claim, :complete),\n         true <- claim.response_partition == Date.utc_today(),",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_partition_clock_mutation",
      test_name:
        "completion trusts the PostgreSQL transaction date across an application date boundary",
      assertion: "assert {:ok, :completed} ="
    },
    "completion-state" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":ok <- validate_claim_state(claim, :complete),",
      mutated: ":ok <- :ok,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "completion-outer" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "defp validate_complete(\n         %Result{\n           status: :complete,\n           reason: nil,\n           admission_dispatch: :sent,\n           transaction: :open,",
      mutated:
        "defp validate_complete(\n         %Result{\n           status: :complete,\n           reason: _reason,\n           admission_dispatch: _dispatch,\n           transaction: _transaction,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_identity_mutation",
      test_name: "completion validates every local encoding and outer evidence field",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "completion-transaction" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "defp transaction_preconditions(target) do\n    if target.repo_module.in_transaction?() do",
      mutated: "defp transaction_preconditions(target) do\n    if true do",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "completion_transaction_mutation",
      test_name:
        "completion outside the caller transaction fails before changing authoritative state",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "untracked-siblings" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "reason: :checkout_unavailable,\n           admission_dispatch: :not_started,\n           transaction: :not_applicable,",
      mutated:
        "reason: _reason,\n           admission_dispatch: _dispatch,\n           transaction: _transaction,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "untracked_siblings_mutation",
      test_name: "exact checkout failure executes untracked only for opted-in idempotency",
      assertion: "assert {:error, %AshOnetime.Error{code: code}} ="
    },
    "admitted-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "true <- claim.id == request.id,",
      mutated: "true <- true,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "fingerprint-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "if :crypto.hash_equals(left, right), do: :match, else: :fingerprint_mismatch",
      mutated: "if is_binary(left), do: :match, else: :fingerprint_mismatch",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "fingerprint_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "operation-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":crypto.hash_equals(claim.operation_hash, request.operation_hash) and",
      mutated: "is_binary(claim.operation_hash) and",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "scope-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":crypto.hash_equals(claim.scope_hash, request.scope_hash) and",
      mutated: "is_binary(claim.scope_hash) and",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "key-identity" => %{
      path: "lib/ash_onetime/admission.ex",
      original: ":crypto.hash_equals(claim.key_hash, request.key_hash)",
      mutated: "is_binary(claim.key_hash)",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "claim_identity_mutation",
      test_name: "mutated admitted claim identity never grants execution",
      assertion: "assert {:error, %AshOnetime.Error{code: :store_invariant}} ="
    },
    "marker-propagation" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "{:replay, _decoded, state} -> AshOnetime.Admission.put_replay(input, state)",
      mutated: "{:replay, _decoded, state} -> AshOnetime.Admission.put_state(input, state)",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "marker_propagation_mutation",
      test_name: "generic original runs once and its typed stored result replays",
      assertion: "assert_receive {:replay_marker, true}"
    },
    "generic-preparation" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original:
        "Ash.ActionInput.before_action(\n      fn pending -> reserve(pending, protection, context) end,",
      mutated: "Ash.ActionInput.before_action(\n      fn pending -> pending end,",
      test: "test/ash_onetime/action_transaction_test.exs",
      tag: "marker_propagation_mutation",
      test_name: "generic original runs once and its typed stored result replays",
      assertion: "assert {:ok, 42} ="
    },
    "notifier-guard" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "if notifiers == [] do",
      mutated: "if is_list(notifiers) do",
      test: "test/compile_fixtures_test.exs",
      tag: "notifier_guard_mutation",
      test_name: "protected CRUD actions reject notifier delivery at compile time",
      assertion: "assert status != 0, output",
      assertion_line: 531
    },
    "around-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "effects: effects,\n           around_action: false,\n           marker: :consumed",
      mutated:
        "effects: effects,\n           around_action: _around_action,\n           marker: :consumed",
      test: "test/compile_fixtures_test.exs",
      tag: "around_guard_mutation",
      test_name: "rejects matrix case local_around_action at its semantic option",
      assertion: "assert status != 0, output",
      required_failures: [
        {"rejects matrix case local_around_action at its semantic option",
         "assert status != 0, output"},
        {"rejects matrix case global_around_action at its semantic option",
         "assert status != 0, output"}
      ],
      assertion_line: 504
    },
    "nonce-around-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "effects: _effects,\n           around_action: false,\n           marker: _marker",
      mutated:
        "effects: _effects,\n           around_action: _around_action,\n           marker: _marker",
      test: "test/compile_fixtures_test.exs",
      tag: "around_guard_mutation",
      test_name: "rejects matrix case nonce_local_around_action at its semantic option",
      assertion: "assert status != 0, output",
      required_failures: [
        {"rejects matrix case nonce_local_around_action at its semantic option",
         "assert status != 0, output"},
        {"rejects matrix case nonce_global_around_action at its semantic option",
         "assert status != 0, output"}
      ],
      assertion_line: 504
    },
    "pure-producer-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "%{notifications: false, effects: false, around_action: false, marker: :unused} =\n           capabilities",
      mutated:
        "%{notifications: _notifications, effects: false, around_action: false, marker: :unused} =\n           capabilities",
      test: "test/compile_fixtures_test.exs",
      tag: "capability_guard_mutation",
      test_name: "rejects matrix case pure_notification_producer at its semantic option",
      assertion: "assert status != 0, output",
      required_failures: [
        {"rejects matrix case pure_notification_producer at its semantic option",
         "assert status != 0, output"},
        {"rejects matrix case global_pure_notification_producer at its semantic option",
         "assert status != 0, output"}
      ],
      assertion_line: 504
    },
    "marker-consumption-capability" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "effects: effects,\n           around_action: false,\n           marker: :consumed",
      mutated: "effects: effects,\n           around_action: false,\n           marker: _marker",
      test: "test/compile_fixtures_test.exs",
      tag: "capability_guard_mutation",
      test_name: "rejects matrix case marker_blind_notification_producer at its semantic option",
      assertion: "assert status != 0, output",
      required_failures: [
        {"rejects matrix case marker_blind_notification_producer at its semantic option",
         "assert status != 0, output"}
      ],
      assertion_line: 504
    },
    "wrapper-protection" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original: "change: {AshOnetime.Change, [protection: protection]},",
      mutated: "change: {AshOnetime.Change, [protection: nil]},",
      test: "test/ash_onetime/resource/verifier_test.exs",
      tag: "wrapper_protection_mutation",
      test_name: "postcompile verifier accepts exact normalized wrapper protection",
      assertion: "protected action is missing exactly one runtime wrapper",
      assertion_line: 22
    },
    "dynamic-repo" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "    %Target{\n      repo_module: repo,\n      dynamic_repo: repo.get_dynamic_repo(),\n      prefix: prefix,\n      logical_partition: logical_partition\n    }",
      mutated:
        "    %Target{\n      repo_module: repo,\n      dynamic_repo: repo,\n      prefix: prefix,\n      logical_partition: logical_partition\n    }",
      test: "test/ash_onetime/store/transaction_test.exs",
      tag: "dynamic_repo_mutation",
      test_name: "two live dynamic repo instances preserve their transaction and quoted prefix",
      assertion: "assert_receive {:live_repo_claimed, ^task_a_pid, :admitted}"
    },
    "prefix-routing" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "quote_identifier(prefix) <> \".\" <> quote_identifier(name)",
      mutated: "quote_identifier(name)",
      test: "test/ash_onetime/tenant_prefix_test.exs",
      tag: "prefix_routing_mutation",
      test_name: "the same complete key is isolated across two tenant prefixes",
      assertion: "assert {:ok, first} = create_in(prefix, input)"
    },
    "authorization-order" => %{
      path: "lib/ash_onetime/change.ex",
      original:
        "protection = Keyword.fetch!(opts, :protection)\n\n    Ash.Changeset.around_action(",
      mutated:
        "protection = Keyword.fetch!(opts, :protection)\n\n    changeset = reserve(changeset, protection, context)\n\n    Ash.Changeset.around_action(",
      test: "test/ash_onetime/authorization_order_test.exs",
      tag: "authorization_order_mutation",
      test_name: "change registration performs no admission callback before Ash authorization",
      assertion: "changeset = Ash.Changeset.for_create(Resource, :charge, valid_input())",
      assertion_line: 16
    },
    "ledger-tamper" => %{
      path: "test/ash_onetime/action_contention_test.exs",
      original: "RAISE EXCEPTION 'action effect ledger is append-only' USING ERRCODE = '23514';",
      mutated: "RETURN OLD;",
      test: "test/ash_onetime/action_contention_test.exs",
      tag: "ledger_tamper_mutation",
      test_name:
        "two protected Ash actions serialize at the authoritative claim and append one effect",
      assertion: "assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ="
    },
    "external-recover" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original: "case module.recover(operation_key, subject, context) do",
      mutated: "case :unknown do",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "external_recover_mutation",
      test_name: "peer success followed by caller death recovers without another execute",
      assertion: "assert [[\"execute\", ^operation_key], [\"recover\", ^operation_key]] =",
      required_failures: [
        {"caller death before peer preserves one key and retry proves absence",
         "assert [[\"recover\", ^operation_key], [\"execute\", ^operation_key]] ="},
        {"peer success followed by caller death recovers without another execute",
         "assert [[\"execute\", ^operation_key], [\"recover\", ^operation_key]] ="},
        {"unknown execute is recovered once immediately",
         "assert [[\"execute\", operation_key], [\"recover\", operation_key]] ="}
      ],
      red_summary: "Result: 0/3 passed, 12 excluded",
      green_summary: "Result: 3 passed, 12 excluded"
    },
    "external-operation-key" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        "defp continue({:recover, state}, subject, protection, context, started) do\n    operation_key = state.claim.id",
      mutated:
        "defp continue({:recover, state}, subject, protection, context, started) do\n    operation_key = state.request.id",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "external_operation_key_mutation",
      test_name: "caller death before peer preserves one key and retry proves absence",
      assertion: "assert [[\"recover\", ^operation_key], [\"execute\", ^operation_key]] ="
    },
    "pre-peer-lock-removed" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        "      case lock_for_peer(state, protection, started) do\n        {:ok, locked} ->\n          execute_then_settle(locked, subject, protection, context, operation_key, started)",
      mutated:
        "      case {:ok, state} do\n        {:ok, locked} ->\n          execute_then_settle(locked, subject, protection, context, operation_key, started)",
      test: "test/ash_onetime/external_contention_test.exs",
      tag: "pre_peer_lock_mutation",
      test_name: "an in-flight retry is refused while the original holds the pre-peer claim lock",
      assertion: "assert {_pid, blockers, query} = wait_for_blocked_query(context.prefix)"
    },
    "effect-lock-generation" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "AND claims.id=$5::uuid",
      mutated: "AND (claims.id=$5::uuid OR true)",
      test: "test/ash_onetime/store/contention_test.exs",
      tag: "effect_lock_generation_mutation",
      test_name: "lock_for_effect refuses a row whose id no longer matches the logical key",
      assertion: "reason: :store_invariant,"
    },
    "ambiguous-retry" => %{
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        ":unknown ->\n        ambiguous_recovery(state, protection, started)\n    end\n  end\n\n  defp execute_then_settle",
      mutated:
        ":unknown ->\n        execute_then_settle(state, subject, protection, context, operation_key, started)\n    end\n  end\n\n  defp execute_then_settle",
      test: "test/ash_onetime/external_recovery_test.exs",
      tag: "ambiguous_retry_mutation",
      test_name: "ambiguous recovery never executes or finalizes",
      assertion:
        "assert ExternalPeer.calls(context.prefix) == calls_before ++ [[\"recover\", operation_key]]"
    },
    "ambiguous-retry-settle" => %{
      tag: "ambiguous_retry_mutation",
      path: "lib/ash_onetime/external_recovery.ex",
      original:
        ":unknown ->\n        ambiguous_recovery(state, protection, started)\n    end\n  end\n\n  # mutation sentinel: ambiguous-retry",
      test: "test/ash_onetime/external_recovery_test.exs",
      test_name:
        "ambiguous outcome from an unknown execute and recover never executes or finalizes",
      assertion: "assert_receive {:external_action_result, ^worker, result}",
      mutated:
        ":unknown ->\n        execute_then_settle(state, subject, protection, callback_context, operation_key, started)\n    end\n  end\n\n  # mutation sentinel: ambiguous-retry",
      assertion_line: 163
    },
    "replay-fence-dispatch" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "      protection.strategy == :one_time_nonce and protection.commit == :independent ->\n        reserve_committed(subject, protection, trusted)",
      mutated:
        "      protection.strategy == :one_time_nonce and protection.commit == :with_action ->\n        reserve_committed(subject, protection, trusted)",
      test: "test/ash_onetime/nonce_rollback_gap_test.exs",
      tag: "replay_fence_dispatch_mutation",
      test_name:
        "commit: :independent (the DPoP replay fence, ADR-0003) a nonce spend survives action-body failure — the proof is NOT re-admitted (FENCE)",
      assertion: ":nonce_already_used",
      assertion_line: 103
    },
    "completion-once" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "      AND id = $8::uuid AND state = 'processing'\#{attempt_bind}\n",
      mutated: "      AND id = $8::uuid AND state = 'complete'\#{attempt_bind}\n",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "completion_once_mutation",
      test_name: "the completion state predicate is the effect-once backstop without a payload",
      assertion: "assert {:error, %Result{status: :failure, reason: :store_invariant}} ="
    },
    "partition-pruning-predicate" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: " AND payload.partition_date=claims.response_partition",
      mutated: "",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "partition_pruning_mutation",
      test_name:
        "load prunes to the authoritative partition and ignores an out-of-partition stray",
      assertion: "assert {:ok, %Result{status: :complete, payload: ^payload}} ="
    },
    "reserved-input" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "with :ok <- reject_reserved(subject),\n         :ok <- reject_external_effect(protection),\n         {:ok, state} <- prepare_resolved(subject, protection),\n         %Result{} = result <- store().claim(state.target, state.request) do",
      mutated:
        "with :ok <- :ok,\n         :ok <- reject_external_effect(protection),\n         {:ok, state} <- prepare_resolved(subject, protection),\n         %Result{} = result <- store().claim(state.target, state.request) do",
      test: "test/ash_onetime/authorization_order_test.exs",
      tag: "reserved_mutation",
      test_name: "reserved verification facts reject before callbacks and SQL",
      assertion: "assert {:error, %AshOnetime.Error{code: :reserved_verification_input}} ="
    },
    "composite-clock" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "issued_at: latest.issued_at,",
      mutated: "issued_at: List.first(verified_facts).issued_at,",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert DateTime.compare(claim.issued_at, latest_issued_at) == :eq"
    },
    "composite-expiry" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "expires_at: nil,",
      mutated: "expires_at: List.first(verified_facts).expires_at,",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert {:ok, %Result{status: :admitted, claim: claim}} ="
    },
    "composite-cleanup" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "|> Enum.max(DateTime)",
      mutated: "|> Enum.min(DateTime)",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert DateTime.compare("
    },
    "composite-verifier-order" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "verifier_ids = Enum.map(verified_facts, & &1.verifier_id)",
      mutated: "verifier_ids = [List.first(verified_facts).verifier_id]",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "composite_clock_mutation",
      test_name:
        "composite nonce persists a coherent aggregate across crossed issuance and expiry",
      assertion: "assert claim.verifier_id == Base.url_encode64(verifier_digest, padding: false)"
    },
    "composite-sibling-validation" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original:
        "Enum.all?(verified_facts, &valid_verified_fact?(&1, evaluated_at, max_age, skew))",
      mutated:
        "Enum.all?([List.last(verified_facts)], &valid_verified_fact?(&1, evaluated_at, max_age, skew))",
      test: "test/ash_onetime/store/postgres_test.exs",
      tag: "composite_sibling_mutation",
      test_name: "one invalid composite nonce sibling rejects the entire admission",
      assertion: "assert {:ok, %Result{status: :failure, reason: :invalid_nonce_window}} ="
    },
    "cache-admission" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "  defp decide(%Result{} = result, state, _protection, _started, _mode) do\n    emit_uncertainty(result, state)\n    {:error, store_error(result)}\n  end",
      mutated:
        "  defp decide(%Result{} = result, %{strategy: :idempotency} = state, protection, started, mode) do\n    if Application.get_env(:ash_onetime, :cache, AshOnetime.Cache.None) != AshOnetime.Cache.None do\n      emit_uncertainty(result, state)\n      {:execute_untracked, %{state | class: :untracked}}\n    else\n      decide(result, state, protection, started, mode, :cache_disabled)\n    end\n  end\n\n  defp decide(%Result{} = result, state, protection, started, mode),\n    do: decide(result, state, protection, started, mode, :cache_disabled)\n\n  defp decide(%Result{} = result, state, _protection, _started, _mode, :cache_disabled) do\n    emit_uncertainty(result, state)\n    {:error, store_error(result)}\n  end",
      test: "test/system/cache_degradation_test.exs",
      tag: "system_cache_admission_mutation",
      test_name: "cache presence cannot admit when authoritative PostgreSQL rejects",
      assertion: "assert {:error, _error} = run(prefix, \"cache-must-not-admit\", 99)"
    },
    "nonce-failure-direction" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "         %{strategy: :idempotency} = state,\n         %{on_definite_store_failure: :execute_untracked},\n         started,\n         :local_claim\n       ) do",
      mutated:
        "         %{strategy: _strategy} = state,\n         _protection,\n         started,\n         :local_claim\n       ) do",
      test: "test/system/failure_direction_test.exs",
      tag: "nonce_failure_direction_mutation",
      test_name:
        "nonce always fails closed while only a definite idempotency checkout can opt out",
      assertion: "assert {:error, %Error{code: :checkout_unavailable}} ="
    },
    "nonce-minted-composite" => %{
      path: "lib/ash_onetime/resource/transformer.ex",
      original:
        "      length(protection.key) > 1 and Enum.any?(protection.key, &match?({:minted, _}, &1)) ->",
      mutated: "      false ->",
      test: "test/compile_fixtures_test.exs",
      tag: "nonce_minted_composite_mutation",
      test_name: "a fresh minted nonce source cannot join a verified key",
      assertion: "assert status != 0, output",
      assertion_line: 523
    },
    "canonical-domain-tag" => %{
      path: "lib/ash_onetime/canonical.ex",
      original: "  @integer_tag 0x02",
      mutated: "  @integer_tag 0x03",
      test: "test/system/package_consumer_test.exs",
      tag: "canonical_domain_tag_mutation",
      test_name: "canonical domains stay distinct and the package starts its callback supervisor",
      assertion: "assert {:ok, <<2, _::binary>>} = Canonical.encode(1)"
    },
    "action-replay" => %{
      path: "lib/ash_onetime/generic_action.ex",
      original: "when class in [:execute, :external_execute, :nonce, :untracked] ->",
      mutated: "when class in [:execute, :external_execute, :nonce, :untracked, :replay] ->",
      test: "test/system/contention_test.exs",
      tag: "action_replay_mutation",
      test_name: "typed replay and action and scope namespaces remain independent",
      assertion: "refute_receive {:generic_run, _}",
      assertion_line: 78
    },
    "for-repo-prefix-bound" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "    unless is_nil(prefix) or valid_prefix?(prefix) do",
      mutated: "    unless is_nil(prefix) or is_binary(prefix) do",
      test: "test/ash_onetime/store/transaction_test.exs",
      tag: "for_repo_prefix_bound_mutation",
      test_name: "for_repo rejects a schema prefix beyond PostgreSQL's 63-byte identifier limit",
      assertion: "Postgres.for_repo(Repo, over_bound)",
      assertion_line: 99
    },
    "prefix-length-bound" => %{
      path: "lib/ash_onetime/store/postgres.ex",
      original: "  defp valid_prefix?(value), do: is_binary(value) and byte_size(value) in 1..63",
      mutated: "  defp valid_prefix?(value), do: is_binary(value) and byte_size(value) in 1..64",
      test: "test/ash_onetime/store/transaction_test.exs",
      tag: "prefix_length_bound_mutation",
      test_name:
        "target rejects a context tenant prefix beyond PostgreSQL's 63-byte identifier limit",
      assertion: "Postgres.target(AshOnetime.Test.TenantStoreResource, tenant: over_bound)"
    },
    "error-splode-membership" => %{
      path: "lib/ash_onetime/error.ex",
      original: "  use Splode.Error, class: :invalid, fields: [:code, :message, :details]",
      mutated:
        "  defexception code: nil, message: nil, details: %{}, class: :invalid, splode: nil, bread_crumbs: [], vars: [], path: [], stacktrace: nil",
      test: "test/ash_onetime/error_test.exs",
      tag: "error_splode_membership_mutation",
      test_name: "Splode integration (ARCH-1) AshOnetime.Error is recognized as an Ash error",
      assertion: "assert Ash.Error.ash_error?(error) == true",
      assertion_line: 11
    },
    "replay-metadata" => %{
      path: "lib/ash_onetime/admission.ex",
      original:
        "        Ash.Resource.put_metadata(record, :ash_onetime, %{replayed: class == :replay})",
      mutated: "        record",
      test: "test/ash_onetime/replay_metadata_test.exs",
      tag: "replay_metadata_mutation",
      test_name:
        "resource create (idempotency, record return) fresh create stamps replayed: false; retry stamps replayed: true",
      assertion: "assert AshOnetime.replayed?(fresh) == false",
      required_failures: [
        {"resource create (idempotency, record return) fresh create stamps replayed: false; retry stamps replayed: true",
         "assert AshOnetime.replayed?(fresh) == false"}
      ],
      assertion_line: 80
    },
    "untracked-transparency" => %{
      path: "lib/ash_onetime/admission.ex",
      original: "  def stamp_replay(%State{class: :untracked}, result), do: result",
      mutated:
        "  def stamp_replay(%State{class: :untracked}, result), do: Ash.Resource.put_metadata(result, :ash_onetime, %{replayed: false})",
      test: "test/ash_onetime/replay_metadata_test.exs",
      tag: "untracked_transparency_mutation",
      test_name:
        ":untracked transparency (ADR 0001) an untracked execution carries no :ash_onetime metadata (replayed? nil)",
      assertion: "assert stamped.__metadata__ == %{}",
      assertion_line: 143
    },
    "verified-key-validation" => %{
      path: "lib/ash_onetime/verified.ex",
      original:
        "      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}\n      _other -> {:error, \"key must be a non-empty binary\"}",
      mutated: "      key -> {:ok, key}",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_key_validation_mutation",
      test_name: "rejects a key that is not a non-empty binary",
      assertion: "Verified.new(key: key, issued_at: @issued_at, verifier_id: @verifier_id)"
    },
    "verified-issued-at-validation" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "    if representable_datetime?(issued_at) do",
      mutated: "    if true do",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_issued_at_validation_mutation",
      test_name: "rejects an issued_at that is not a DateTime",
      assertion: "Verified.new(key: \"nonce-1\", issued_at: issued_at, verifier_id: @verifier_id)"
    },
    "verified-verifier-id-bound" => %{
      path: "lib/ash_onetime/verified.ex",
      original:
        "      verifier_id\n" <>
          "      when is_binary(verifier_id) and byte_size(verifier_id) > 0 and\n" <>
          "             byte_size(verifier_id) <= @max_verifier_id_bytes ->\n" <>
          "        {:ok, verifier_id}\n" <>
          "\n" <>
          "      _other ->\n" <>
          "        {:error,\n" <>
          "         \"verifier_id must be a non-empty binary of at most \#{@max_verifier_id_bytes} bytes\"}",
      mutated: "      verifier_id ->\n        {:ok, verifier_id}",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_verifier_id_bound_mutation",
      test_name: "rejects a verifier_id that is not a non-empty binary within the 128-byte bound",
      assertion: "Verified.new(key: \"nonce-1\", issued_at: @issued_at, verifier_id: verifier_id)"
    },
    "verified-expiry-order" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "    if DateTime.compare(expires_at, issued_at) in [:eq, :gt] do",
      mutated: "    if DateTime.compare(expires_at, issued_at) in [:eq, :gt, :lt] do",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_expiry_order_mutation",
      test_name: "rejects an expires_at before issued_at",
      assertion: "expires_at: ~U[2026-09-20 11:59:59Z]"
    },
    "verified-unknown-keys" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "    unknown = Enum.uniq(keys -- @known_keys)",
      mutated: "    unknown = []",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_unknown_keys_mutation",
      test_name: "rejects unknown keys",
      assertion: "verifier: @verifier_id"
    },
    "verified-shape-rejection" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "  def new(_fields), do: {:error, \"verified facts must be a keyword list\"}",
      mutated: "  def new(_fields), do: {:ok, nil}",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_shape_rejection_mutation",
      test_name: "rejects input that is not a keyword list",
      assertion: "Verified.new(%{key: \"nonce-1\"})"
    },
    "verified-expires-at-validation" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "      true -> {:error, \"expires_at must be a DateTime or nil\"}",
      mutated: "      true -> {:ok, nil}",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_expires_at_validation_mutation",
      test_name: "rejects an expires_at that is neither nil nor a DateTime",
      assertion: "assert {:error, \"expires_at must be a DateTime or nil\"}"
    },
    "verified-duplicate-keys" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "      map_size(Map.new(fields)) != length(fields) ->",
      mutated: "      false ->",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_duplicate_keys_mutation",
      test_name: "rejects duplicate keys",
      assertion: "assert reason =~ \"unique\""
    },
    "verified-missing-required" => %{
      path: "lib/ash_onetime/verified.ex",
      original: "    missing = Enum.uniq(@required_keys -- keys)",
      mutated: "    missing = []",
      test: "test/ash_onetime/verified_test.exs",
      tag: "verified_missing_required_mutation",
      test_name: "rejects a missing required key",
      assertion: "** (KeyError)",
      assertion_line: 100
    }
  }

  @forbidden_telemetry [
    scope: "raw-scope",
    scope_hash: <<0::256>>,
    key: "raw-key",
    key_hash: <<0::256>>,
    token: "token",
    fingerprint: <<0::256>>,
    response: "response",
    payload: "payload",
    signature: "signature",
    resolver_id: "resolver",
    verifier_id: "verifier",
    secret: "secret",
    store_result: %{status: :failure},
    exception: %RuntimeError{message: "sensitive"}
  ]

  @telemetry_builder """
  metadata = %{
          strategy: strategy,
          resource: resource,
          action: action,
          result_class: result_class
        }
  """

  @mutations Enum.reduce(@forbidden_telemetry, @mutations, fn {field, value}, mutations ->
               mutated =
                 "metadata = Map.put(%{\n" <>
                   "        strategy: strategy,\n" <>
                   "        resource: resource,\n" <>
                   "        action: action,\n" <>
                   "        result_class: result_class\n" <>
                   "      }, #{inspect(field)}, #{inspect(value, limit: :infinity)})\n"

               Map.put(mutations, "telemetry-#{field}", %{
                 path: "lib/ash_onetime/telemetry.ex",
                 original: @telemetry_builder,
                 mutated: mutated,
                 test: "test/ash_onetime/action_transaction_test.exs",
                 tag: "actual_telemetry_mutation",
                 test_name: "actual admission paths emit every closed telemetry family",
                 assertion:
                   "assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]"
               })
             end)

  # Complete enforcement inventory.
  @mutations Map.merge(@mutations, %{
               "nonce-select-lock" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "select_claim_result(target, strategy, sql <> \" FOR \#{lock_mode} OF claims\", parameters)",
                 mutated: "select_claim_result(target, strategy, sql, parameters)",
                 test: "test/ash_onetime/external_state/lock_matrix_test.exs",
                 tag: "enforcement_nonce_select_lock_mutation",
                 test_name: "plain: nonce load waits for the native row lock",
                 assertion:
                   "assert_receive {:nonce_load, %Result{status: :failure, reason: :lock_timeout}}",
                 assertion_line: 155,
                 required_failures: [
                   %{
                     test_name: "plain: nonce load waits for the native row lock",
                     assertion:
                       "assert_receive {:nonce_load, %Result{status: :failure, reason: :lock_timeout}}",
                     assertion_line: 155
                   },
                   %{
                     test_name: "2: nonce load waits for the native row lock",
                     assertion:
                       "assert_receive {:nonce_load, %Result{status: :failure, reason: :lock_timeout}}",
                     assertion_line: 155
                   }
                 ]
               },
               "idempotency-claims-check-logical-partition" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_logical_partition_check CHECK (octet_length(logical_partition) BETWEEN 1 AND 255)",
                 mutated:
                   "CONSTRAINT ash_onetime_idempotency_claims_logical_partition_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_logical_partition_mutation",
                 test_name:
                   "plain: ash_onetime_idempotency_claims rejects invalid logical-partition",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_idempotency_claims rejects invalid logical-partition",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name:
                       "2: ash_onetime_idempotency_claims rejects invalid logical-partition",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-operation-hash" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_operation_hash_check CHECK (octet_length(operation_hash) = 32)",
                 mutated:
                   "CONSTRAINT ash_onetime_idempotency_claims_operation_hash_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_operation_hash_mutation",
                 test_name:
                   "plain: ash_onetime_idempotency_claims rejects invalid operation-hash",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_idempotency_claims rejects invalid operation-hash",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name:
                       "2: ash_onetime_idempotency_claims rejects invalid operation-hash",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-scope-hash" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_scope_hash_check CHECK (octet_length(scope_hash) = 32)",
                 mutated:
                   "CONSTRAINT ash_onetime_idempotency_claims_scope_hash_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_scope_hash_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid scope-hash",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_idempotency_claims rejects invalid scope-hash",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid scope-hash",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-key-hash" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_key_hash_check CHECK (octet_length(key_hash) = 32)",
                 mutated: "CONSTRAINT ash_onetime_idempotency_claims_key_hash_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_key_hash_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid key-hash",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_idempotency_claims rejects invalid key-hash",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid key-hash",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-fingerprint" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_fingerprint_check CHECK (octet_length(fingerprint) = 32)",
                 mutated:
                   "CONSTRAINT ash_onetime_idempotency_claims_fingerprint_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_fingerprint_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid fingerprint",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_idempotency_claims rejects invalid fingerprint",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid fingerprint",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-state" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_state_check CHECK (state IN ('processing', 'complete'))",
                 mutated: "CONSTRAINT ash_onetime_idempotency_claims_state_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_state_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid state",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_idempotency_claims rejects invalid state",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid state",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-hold" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_hold_check\n        CHECK (hold_reference IS NULL OR (octet_length(hold_reference) >= 1 AND octet_length(hold_reference) <= 255 AND state = 'complete'))",
                 mutated: "CONSTRAINT ash_onetime_idempotency_claims_hold_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_hold_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid hold",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_idempotency_claims rejects invalid hold",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid hold",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-retention" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_check CHECK (retain_until > admitted_at)",
                 mutated: "CONSTRAINT ash_onetime_idempotency_claims_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_retention_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid retention",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_idempotency_claims rejects invalid retention",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid retention",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-check-inserted-at" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_check1 CHECK (inserted_at >= admitted_at)",
                 mutated: "CONSTRAINT ash_onetime_idempotency_claims_check1 CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_check_inserted_at_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims rejects invalid inserted-at",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_idempotency_claims rejects invalid inserted-at",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims rejects invalid inserted-at",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-logical-partition" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_logical_partition_check CHECK (octet_length(logical_partition) BETWEEN 1 AND 255)",
                 mutated:
                   "CONSTRAINT ash_onetime_nonce_claims_logical_partition_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_logical_partition_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid logical-partition",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_nonce_claims rejects invalid logical-partition",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid logical-partition",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-operation-hash" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_operation_hash_check CHECK (octet_length(operation_hash) = 32)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_operation_hash_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_operation_hash_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid operation-hash",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims rejects invalid operation-hash",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid operation-hash",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-scope-hash" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_scope_hash_check CHECK (octet_length(scope_hash) = 32)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_scope_hash_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_scope_hash_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid scope-hash",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims rejects invalid scope-hash",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid scope-hash",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-key-hash" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_key_hash_check CHECK (octet_length(key_hash) = 32)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_key_hash_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_key_hash_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid key-hash",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims rejects invalid key-hash",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid key-hash",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-verifier-id" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_verifier_id_check CHECK (octet_length(verifier_id) BETWEEN 1 AND 128)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_verifier_id_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_verifier_id_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid verifier-id",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims rejects invalid verifier-id",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid verifier-id",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-expiry" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_check CHECK (expires_at IS NULL OR expires_at >= issued_at)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_expiry_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid expiry",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims rejects invalid expiry",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid expiry",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-issued-retention" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_check1 CHECK (retain_until > issued_at)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_check1 CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_issued_retention_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid issued-retention",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_nonce_claims rejects invalid issued-retention",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid issued-retention",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-admitted-retention" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_check2 CHECK (retain_until > admitted_at)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_check2 CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_admitted_retention_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid admitted-retention",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_nonce_claims rejects invalid admitted-retention",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid admitted-retention",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-check-inserted-at" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_check3 CHECK (inserted_at >= admitted_at)",
                 mutated: "CONSTRAINT ash_onetime_nonce_claims_check3 CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_check_inserted_at_mutation",
                 test_name: "plain: ash_onetime_nonce_claims rejects invalid inserted-at",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims rejects invalid inserted-at",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims rejects invalid inserted-at",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "response-payloads-check-logical-partition" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_response_payloads_logical_partition_check CHECK (octet_length(logical_partition) BETWEEN 1 AND 255)",
                 mutated:
                   "CONSTRAINT ash_onetime_response_payloads_logical_partition_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_response_payloads_check_logical_partition_mutation",
                 test_name:
                   "plain: ash_onetime_response_payloads rejects invalid logical-partition",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_response_payloads rejects invalid logical-partition",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name:
                       "2: ash_onetime_response_payloads rejects invalid logical-partition",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "response-payloads-check-size" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_response_payloads_encoded_response_check CHECK (octet_length(encoded_response) <= \#{@payload_ceiling})",
                 mutated:
                   "CONSTRAINT ash_onetime_response_payloads_encoded_response_check CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_response_payloads_check_size_mutation",
                 test_name: "plain: ash_onetime_response_payloads rejects invalid size",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_response_payloads rejects invalid size",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_response_payloads rejects invalid size",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "idempotency-claims-primary-key" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_idempotency_claims_pkey PRIMARY KEY (<%= if hash_partitions, do: \"operation_hash, logical_partition, \" %>id),",
                 mutated: "",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_idempotency_claims_primary_key_mutation",
                 test_name: "plain: ash_onetime_idempotency_claims refuses a repeated claim id",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_idempotency_claims refuses a repeated claim id",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_idempotency_claims refuses a repeated claim id",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "nonce-claims-primary-key" => %{
                 path: "priv/templates/migrations/install.exs",
                 original:
                   "CONSTRAINT ash_onetime_nonce_claims_pkey PRIMARY KEY (<%= if hash_partitions, do: \"operation_hash, logical_partition, \" %>id),",
                 mutated: "",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_nonce_claims_primary_key_mutation",
                 test_name: "plain: ash_onetime_nonce_claims refuses a repeated claim id",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_nonce_claims refuses a repeated claim id",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: ash_onetime_nonce_claims refuses a repeated claim id",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "payload-primary-key" => %{
                 path: "priv/templates/migrations/install.exs",
                 original: "PRIMARY KEY (logical_partition, partition_date, claim_id)",
                 mutated:
                   "UNIQUE (logical_partition, partition_date, claim_id, encoded_response)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_payload_primary_key_mutation",
                 test_name: "plain: payloads refuse a repeated claim and partition",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: payloads refuse a repeated claim and partition",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: payloads refuse a repeated claim and partition",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "facts-check-tenant" => %{
                 path: "priv/templates/migrations/fact_tables.exs",
                 original: "CHECK (octet_length(tenant) BETWEEN 1 AND 255)",
                 mutated: "CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_facts_check_tenant_mutation",
                 test_name: "plain: facts reject invalid tenant",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: facts reject invalid tenant",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: facts reject invalid tenant",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "facts-check-type" => %{
                 path: "priv/templates/migrations/fact_tables.exs",
                 original: "CHECK (octet_length(type) BETWEEN 1 AND 255)",
                 mutated: "CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_facts_check_type_mutation",
                 test_name: "plain: facts reject invalid type",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: facts reject invalid type",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: facts reject invalid type",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "facts-check-tags" => %{
                 path: "priv/templates/migrations/fact_tables.exs",
                 original: "CHECK (\#{q(\"ash_onetime_fact_tags_valid\")}(tags))",
                 mutated: "CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_facts_check_tags_mutation",
                 test_name: "plain: facts reject invalid tags",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: facts reject invalid tags",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: facts reject invalid tags",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "facts-primary-key" => %{
                 path: "priv/templates/migrations/fact_tables.exs",
                 original: "seq bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY",
                 mutated: "seq bigint GENERATED BY DEFAULT AS IDENTITY",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_facts_primary_key_mutation",
                 test_name: "plain: facts refuse a repeated sequence",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: facts refuse a repeated sequence",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: facts refuse a repeated sequence",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "facts-append-only-refusal" => %{
                 path: "priv/templates/migrations/fact_tables.exs",
                 original:
                   "RAISE EXCEPTION 'fact table % is append-only', TG_TABLE_NAME USING ERRCODE = '23514';",
                 mutated: "RETURN OLD;",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_facts_append_only_refusal_mutation",
                 test_name: "plain: fact updates are refused",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: fact updates are refused",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: fact updates are refused",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "maintenance-runs-primary-key" => %{
                 path: "priv/templates/migrations/maintenance/runs.sql",
                 original: "step text PRIMARY KEY",
                 mutated: "step text",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_maintenance_runs_primary_key_mutation",
                 test_name: "plain: maintenance steps cannot be duplicated",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: maintenance steps cannot be duplicated",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: maintenance steps cannot be duplicated",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "maintenance-runs-check-step" => %{
                 path: "priv/templates/migrations/maintenance/runs.sql",
                 original: "CHECK (step IN ('install','roll','cleanup','reap','prune'))",
                 mutated: "CHECK (true)",
                 test: "test/ash_onetime/external_state/schema_constraints_test.exs",
                 tag: "enforcement_maintenance_runs_check_step_mutation",
                 test_name: "plain: maintenance refuses an unknown step",
                 assertion: "assert",
                 assertion_line: 174,
                 required_failures: [
                   %{
                     test_name: "plain: maintenance refuses an unknown step",
                     assertion: "assert",
                     assertion_line: 174
                   },
                   %{
                     test_name: "2: maintenance refuses an unknown step",
                     assertion: "assert",
                     assertion_line: 174
                   }
                 ]
               },
               "maintenance-routine-support" => %{
                 tag: "routine_executable_mutation",
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 test: "test/ash_onetime/store/maintenance_test.exs",
                 assertion: "assert_refusal",
                 original: "RAISE EXCEPTION 'untrusted_dependency: routine support';",
                 mutated: "NULL;",
                 test_name: "executable pg_proc metadata rejects support",
                 assertion_line: 4383
               },
               "maintenance-routine-executable-trees" => %{
                 tag: "routine_executable_mutation",
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 test: "test/ash_onetime/store/maintenance_test.exs",
                 assertion: "assert_refusal",
                 original: "RAISE EXCEPTION 'untrusted_dependency: routine executable trees';",
                 mutated: "NULL;",
                 test_name: "executable pg_proc metadata rejects argument_default",
                 assertion_line: 4679
               },
               "claim-trigger-inline-active" => %{
                 tag: "external_state_claim_trigger_mutation",
                 path: "priv/templates/migrations/external_state/claims.sql",
                 original:
                   "coalesce(current_setting('ash_onetime.maintenance', true) = 'on', false)\n      AND current_user = (SELECT r.rolname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_roles r ON r.oid=c.relowner WHERE c.oid=TG_RELID)",
                 test: "test/ash_onetime/external_state/claim_trigger_test.exs",
                 assertion_line: 196,
                 test_name: "expiry refuses runtime with SQLSTATE 23514",
                 assertion: "assert",
                 mutated: "@routines@.ash_onetime_maintenance_active()"
               },
               "claim-trigger-inline-eligible" => %{
                 tag: "external_state_inline_eligible_mutation",
                 path: "priv/templates/migrations/external_state/claims.sql",
                 original: "transaction_timestamp() > OLD.response_retain_until",
                 test: "test/ash_onetime/external_state/inline_predicate_test.exs",
                 assertion_line: 31,
                 test_name: "plain: early expiry uses its inline deadline predicate",
                 assertion: "assert",
                 mutated: "@routines@.ash_onetime_cleanup_eligible(OLD.response_retain_until)",
                 required_failures: [
                   %{
                     test_name: "plain: early expiry uses its inline deadline predicate",
                     assertion: "assert",
                     assertion_line: 31
                   },
                   %{
                     test_name: "2: early expiry uses its inline deadline predicate",
                     assertion: "assert",
                     assertion_line: 31
                   }
                 ]
               },
               "cleanup-idempotency-arguments" => %{
                 path: "priv/templates/migrations/maintenance/cleanup_idempotency.sql",
                 original:
                   "RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/argument_guards_test.exs",
                 tag: "enforcement_cleanup_idempotency_arguments_mutation",
                 test_name: "plain: ash_onetime_cleanup_idempotency refuses NULL",
                 assertion: "assert",
                 assertion_line: 30,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_cleanup_idempotency refuses NULL",
                     assertion: "assert",
                     assertion_line: 30
                   },
                   %{
                     test_name: "2: ash_onetime_cleanup_idempotency refuses NULL",
                     assertion: "assert",
                     assertion_line: 30
                   }
                 ]
               },
               "cleanup-nonce-arguments" => %{
                 path: "priv/templates/migrations/maintenance/cleanup_nonce.sql",
                 original:
                   "RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/argument_guards_test.exs",
                 tag: "enforcement_cleanup_nonce_arguments_mutation",
                 test_name: "plain: ash_onetime_cleanup_nonce refuses NULL",
                 assertion: "assert",
                 assertion_line: 30,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_cleanup_nonce refuses NULL",
                     assertion: "assert",
                     assertion_line: 30
                   },
                   %{
                     test_name: "2: ash_onetime_cleanup_nonce refuses NULL",
                     assertion: "assert",
                     assertion_line: 30
                   }
                 ]
               },
               "expire-arguments" => %{
                 path: "priv/templates/migrations/maintenance/expire.sql",
                 original: "RAISE EXCEPTION 'invalid expiry batch size' USING ERRCODE='22023';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/argument_guards_test.exs",
                 tag: "enforcement_expire_arguments_mutation",
                 test_name: "plain: ash_onetime_expire_responses refuses NULL",
                 assertion: "assert",
                 assertion_line: 30,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_expire_responses refuses NULL",
                     assertion: "assert",
                     assertion_line: 30
                   },
                   %{
                     test_name: "2: ash_onetime_expire_responses refuses NULL",
                     assertion: "assert",
                     assertion_line: 30
                   }
                 ]
               },
               "reap-batch-arguments" => %{
                 path: "priv/templates/migrations/maintenance/reap.sql",
                 original: "RAISE EXCEPTION 'invalid reap batch size' USING ERRCODE = '22023';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/argument_guards_test.exs",
                 tag: "enforcement_reap_batch_arguments_mutation",
                 test_name: "plain: ash_onetime_reap_idempotency refuses NULL,86400",
                 assertion: "assert",
                 assertion_line: 30,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_reap_idempotency refuses NULL,86400",
                     assertion: "assert",
                     assertion_line: 30
                   },
                   %{
                     test_name: "2: ash_onetime_reap_idempotency refuses NULL,86400",
                     assertion: "assert",
                     assertion_line: 30
                   }
                 ]
               },
               "reap-horizon-arguments" => %{
                 path: "priv/templates/migrations/maintenance/reap.sql",
                 original:
                   "RAISE EXCEPTION 'invalid reap abandonment horizon (86400..315576000000 seconds)' USING ERRCODE = '22023';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/argument_guards_test.exs",
                 tag: "enforcement_reap_horizon_arguments_mutation",
                 test_name: "plain: ash_onetime_reap_idempotency refuses 1,NULL",
                 assertion: "assert",
                 assertion_line: 30,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_reap_idempotency refuses 1,NULL",
                     assertion: "assert",
                     assertion_line: 30
                   },
                   %{
                     test_name: "2: ash_onetime_reap_idempotency refuses 1,NULL",
                     assertion: "assert",
                     assertion_line: 30
                   }
                 ]
               },
               "prune-arguments" => %{
                 path: "priv/templates/migrations/maintenance/prune.sql",
                 original: "RAISE EXCEPTION 'invalid prune bounds' USING ERRCODE='22023';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/argument_guards_test.exs",
                 tag: "enforcement_prune_arguments_mutation",
                 test_name: "plain: ash_onetime_prune_payload_partitions refuses NULL,100",
                 assertion: "assert",
                 assertion_line: 30,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_prune_payload_partitions refuses NULL,100",
                     assertion: "assert",
                     assertion_line: 30
                   },
                   %{
                     test_name: "2: ash_onetime_prune_payload_partitions refuses NULL,100",
                     assertion: "assert",
                     assertion_line: 30
                   }
                 ]
               },
               "roll-default-force-1" => %{
                 path: "priv/templates/migrations/maintenance/roll.sql",
                 original:
                   "    IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=default_oid) THEN\n      RAISE EXCEPTION 'prune_blocked: FORCE reapplied to DEFAULT';\n    END IF;",
                 mutated:
                   "    IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=default_oid) THEN\n      NULL;\n    END IF;",
                 test: "test/ash_onetime/external_state/roll_refusal_test.exs",
                 tag: "enforcement_roll_default_force_1_mutation",
                 test_name: "plain: rolling refuses DEFAULT FORCE reapplied at phase 1",
                 assertion: "assert",
                 assertion_line: 62,
                 required_failures: [
                   %{
                     test_name: "plain: rolling refuses DEFAULT FORCE reapplied at phase 1",
                     assertion: "assert",
                     assertion_line: 62
                   },
                   %{
                     test_name: "2: rolling refuses DEFAULT FORCE reapplied at phase 1",
                     assertion: "assert",
                     assertion_line: 62
                   }
                 ]
               },
               "roll-default-force-2" => %{
                 path: "priv/templates/migrations/maintenance/roll.sql",
                 original:
                   "        IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=default_oid) THEN\n          RAISE EXCEPTION 'prune_blocked: FORCE reapplied to DEFAULT';\n        END IF;",
                 mutated:
                   "        IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=default_oid) THEN\n          NULL;\n        END IF;",
                 test: "test/ash_onetime/external_state/roll_refusal_test.exs",
                 tag: "enforcement_roll_default_force_2_mutation",
                 test_name: "plain: rolling refuses DEFAULT FORCE reapplied at phase 2",
                 assertion: "assert",
                 assertion_line: 62,
                 required_failures: [
                   %{
                     test_name: "plain: rolling refuses DEFAULT FORCE reapplied at phase 2",
                     assertion: "assert",
                     assertion_line: 62
                   },
                   %{
                     test_name: "2: rolling refuses DEFAULT FORCE reapplied at phase 2",
                     assertion: "assert",
                     assertion_line: 62
                   }
                 ]
               },
               "roll-reraise" => %{
                 path: "priv/templates/migrations/maintenance/roll.sql",
                 original: "RAISE;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/store/maintenance_test.exs",
                 tag: "recovery_failure",
                 test_name:
                   "DEFAULT recovery failure at move changes no rows, partitions, flags, ACLs, or records",
                 assertion: "assert",
                 assertion_line: 4528
               },
               "inventory-unmarked-reraise" => %{
                 path: "scripts/mutation_inventory.exs",
                 original: "@enforcer ~r/\\bRAISE\\b",
                 mutated: "@enforcer ~r/\\bRAISE\\s+(?:EXCEPTION|SQLSTATE)\\b",
                 test: "test/ash_onetime/external_state/proof_inventory_test.exs",
                 tag: "external_state_inventory_unmarked_reraise",
                 test_name:
                   "the inventory refuses an unmarked re-raise in the rendered roll routine",
                 assertion: "assert_raise",
                 assertion_line: 134
               },
               "routine-step-definer" => %{
                 path: "priv/templates/migrations/maintenance/settings.sql",
                 original: "DEFINER",
                 mutated: "INVOKER",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_routine_step_definer_mutation",
                 test_name: "plain: ash_onetime_cleanup_nonce fixes routine-step-definer",
                 assertion: "assert",
                 assertion_line: 32,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_cleanup_nonce fixes routine-step-definer",
                     assertion: "assert",
                     assertion_line: 32
                   },
                   %{
                     test_name: "2: ash_onetime_cleanup_nonce fixes routine-step-definer",
                     assertion: "assert",
                     assertion_line: 32
                   }
                 ]
               },
               "routine-helper-invoker" => %{
                 path: "priv/templates/migrations/maintenance/settings.sql",
                 original: "INVOKER",
                 mutated: "DEFINER",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_routine_helper_invoker_mutation",
                 test_name: "plain: ash_onetime_cleanup_eligible fixes routine-helper-invoker",
                 assertion: "assert",
                 assertion_line: 32,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_cleanup_eligible fixes routine-helper-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   },
                   %{
                     test_name: "2: ash_onetime_cleanup_eligible fixes routine-helper-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   }
                 ]
               },
               "routine-inside-search-path" => %{
                 path: "priv/templates/migrations/maintenance/settings.sql",
                 original:
                   "SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = on",
                 mutated:
                   "SET search_path = public SET DateStyle = 'ISO, YMD' SET row_security = on",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_routine_inside_search_path_mutation",
                 test_name:
                   "plain: ash_onetime_cleanup_eligible fixes routine-inside-search-path",
                 assertion: "assert",
                 assertion_line: 39,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_cleanup_eligible fixes routine-inside-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   },
                   %{
                     test_name:
                       "2: ash_onetime_cleanup_eligible fixes routine-inside-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   }
                 ]
               },
               "outcome-bound-search-path" => %{
                 path: "priv/templates/migrations/external_state/outcomes.sql",
                 original: "SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD'\n",
                 mutated: "SET search_path = public SET DateStyle = 'ISO, YMD'\n",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_outcome_bound_search_path_mutation",
                 test_name:
                   "plain: ash_onetime_bound_effect_outcome fixes outcome-bound-search-path",
                 assertion: "assert",
                 assertion_line: 39,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_bound_effect_outcome fixes outcome-bound-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   },
                   %{
                     test_name:
                       "2: ash_onetime_bound_effect_outcome fixes outcome-bound-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   }
                 ]
               },
               "outcome-guard-search-path" => %{
                 path: "priv/templates/migrations/external_state/outcomes.sql",
                 original:
                   "SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = off",
                 mutated:
                   "SET search_path = public SET DateStyle = 'ISO, YMD' SET row_security = off",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_outcome_guard_search_path_mutation",
                 test_name:
                   "plain: ash_onetime_guard_effect_outcome fixes outcome-guard-search-path",
                 assertion: "assert",
                 assertion_line: 39,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_guard_effect_outcome fixes outcome-guard-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   },
                   %{
                     test_name:
                       "2: ash_onetime_guard_effect_outcome fixes outcome-guard-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   }
                 ]
               },
               "visibility-helper-search-path" => %{
                 path: "priv/templates/migrations/external_state/outcomes.sql",
                 original:
                   "SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = on",
                 mutated:
                   "SET search_path = public SET DateStyle = 'ISO, YMD' SET row_security = on",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_visibility_helper_search_path_mutation",
                 test_name:
                   "plain: ash_onetime_claim_visible fixes visibility-helper-search-path",
                 assertion: "assert",
                 assertion_line: 39,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_claim_visible fixes visibility-helper-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   },
                   %{
                     test_name:
                       "2: ash_onetime_claim_visible fixes visibility-helper-search-path",
                     assertion: "assert",
                     assertion_line: 39
                   }
                 ]
               },
               "install-routine-security" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE %s %s SECURITY %s %s AS %L',",
                 mutated:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE %s %s /* %s */ %s AS %L',",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_install_routine_security_mutation",
                 test_name: "plain: ash_onetime_cleanup_nonce fixes install-routine-security",
                 assertion: "assert",
                 assertion_line: 32,
                 required_failures: [
                   %{
                     test_name: "plain: ash_onetime_cleanup_nonce fixes install-routine-security",
                     assertion: "assert",
                     assertion_line: 32
                   },
                   %{
                     test_name: "2: ash_onetime_cleanup_nonce fixes install-routine-security",
                     assertion: "assert",
                     assertion_line: 32
                   }
                 ]
               },
               "complete-candidate-lock" => %{
                 path: "priv/templates/migrations/maintenance/cleanup_idempotency.sql",
                 original: "FOR UPDATE SKIP LOCKED LIMIT batch_size",
                 mutated: "FOR NO KEY UPDATE SKIP LOCKED LIMIT batch_size",
                 test: "test/ash_onetime/external_state/maintenance_row_locks_test.exs",
                 tag: "enforcement_complete_candidate_lock_mutation",
                 test_name:
                   "plain: complete candidates skip a held KEY SHARE without waiting for DELETE",
                 assertion: "assert",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: complete candidates skip a held KEY SHARE without waiting for DELETE",
                     assertion: "assert",
                     assertion_line: 52
                   },
                   %{
                     test_name:
                       "2: complete candidates skip a held KEY SHARE without waiting for DELETE",
                     assertion: "assert",
                     assertion_line: 52
                   }
                 ]
               },
               "nonce-candidate-lock" => %{
                 path: "priv/templates/migrations/maintenance/cleanup_nonce.sql",
                 original: "FOR UPDATE SKIP LOCKED LIMIT batch_size",
                 mutated: "FOR NO KEY UPDATE SKIP LOCKED LIMIT batch_size",
                 test: "test/ash_onetime/external_state/maintenance_row_locks_test.exs",
                 tag: "enforcement_nonce_candidate_lock_mutation",
                 test_name:
                   "plain: nonce candidates skip a held KEY SHARE without waiting for DELETE",
                 assertion: "assert",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: nonce candidates skip a held KEY SHARE without waiting for DELETE",
                     assertion: "assert",
                     assertion_line: 52
                   },
                   %{
                     test_name:
                       "2: nonce candidates skip a held KEY SHARE without waiting for DELETE",
                     assertion: "assert",
                     assertion_line: 52
                   }
                 ]
               },
               "processing-candidate-lock" => %{
                 path: "priv/templates/migrations/maintenance/reap.sql",
                 original: "FOR UPDATE SKIP LOCKED LIMIT batch_size",
                 mutated: "FOR NO KEY UPDATE SKIP LOCKED LIMIT batch_size",
                 test: "test/ash_onetime/external_state/maintenance_row_locks_test.exs",
                 tag: "enforcement_processing_candidate_lock_mutation",
                 test_name:
                   "plain: processing candidates skip a held KEY SHARE without waiting for DELETE",
                 assertion: "assert",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: processing candidates skip a held KEY SHARE without waiting for DELETE",
                     assertion: "assert",
                     assertion_line: 52
                   },
                   %{
                     test_name:
                       "2: processing candidates skip a held KEY SHARE without waiting for DELETE",
                     assertion: "assert",
                     assertion_line: 52
                   }
                 ]
               },
               "maintenance-root-column-authority" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original:
                   "CASE WHEN t.append_only THEN 'UPDATE,REFERENCES' WHEN t.owner_only THEN 'SELECT,INSERT,UPDATE,REFERENCES' ELSE 'REFERENCES' END",
                 mutated:
                   "CASE WHEN t.append_only THEN 'UPDATE,REFERENCES' WHEN t.owner_only THEN 'SELECT,INSERT,UPDATE,REFERENCES' ELSE 'REFERENCES WITH GRANT OPTION' END",
                 test: "test/ash_onetime/store/maintenance_test.exs",
                 tag: "effective_root_authority_mutation",
                 test_name:
                   "effective root authority refuses REFERENCES (id) on ash_onetime_idempotency_claims",
                 assertion: "refute scalar(",
                 required_failures: [
                   %{
                     test_name:
                       "effective root authority refuses REFERENCES on ash_onetime_idempotency_claims",
                     assertion: "refute scalar("
                   },
                   %{
                     test_name:
                       "effective root authority refuses REFERENCES (id) on ash_onetime_idempotency_claims",
                     assertion: "refute scalar("
                   },
                   %{
                     test_name:
                       "effective root authority refuses REFERENCES on ash_onetime_nonce_claims",
                     assertion: "refute scalar("
                   },
                   %{
                     test_name:
                       "effective root authority refuses REFERENCES (id) on ash_onetime_nonce_claims",
                     assertion: "refute scalar("
                   },
                   %{
                     test_name:
                       "effective root authority refuses REFERENCES on ash_onetime_response_payloads",
                     assertion: "refute scalar("
                   },
                   %{
                     test_name:
                       "effective root authority refuses REFERENCES (claim_id) on ash_onetime_response_payloads",
                     assertion: "refute scalar("
                   }
                 ],
                 assertion_line: 5557
               },
               "current-delete-unarmed" => %{
                 path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
                 original:
                   "      -- rule:current-delete-unarmed\n      RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted' USING ERRCODE = '23514';",
                 mutated: "      -- rule:current-delete-unarmed\n      NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_current_delete_unarmed_mutation",
                 test_name: "plain: current delete refuses unarmed at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: current delete refuses unarmed at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: current delete refuses unarmed at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "current-delete-processing-payload" => %{
                 path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
                 original:
                   "      -- rule:current-delete-processing-payload\n      RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload' USING ERRCODE = '23514';",
                 mutated: "      -- rule:current-delete-processing-payload\n      NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_current_delete_processing_payload_mutation",
                 test_name:
                   "plain: current delete refuses processing_payload at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name:
                       "plain: current delete refuses processing_payload at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name:
                       "2: current delete refuses processing_payload at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "current-delete-count-after" => %{
                 path: "priv/templates/migrations/maintenance/guard_idempotency.sql",
                 original:
                   "    -- rule:current-delete-count-after\n    RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE = '23514';",
                 mutated: "    -- rule:current-delete-count-after\n    NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_current_delete_count_after_mutation",
                 test_name: "plain: current delete refuses count_after at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: current delete refuses count_after at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: current delete refuses count_after at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-unarmed" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "          -- rule:hold-delete-unarmed\n          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'\n            USING ERRCODE = '23514';",
                 mutated: "          -- rule:hold-delete-unarmed\n          NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_unarmed_mutation",
                 test_name: "plain: hold delete refuses unarmed at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: hold delete refuses unarmed at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses unarmed at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-boundary" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "          -- rule:hold-delete-boundary\n          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'\n            USING ERRCODE = '23514';",
                 mutated: "          -- rule:hold-delete-boundary\n          NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_boundary_mutation",
                 test_name: "plain: hold delete refuses boundary at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: hold delete refuses boundary at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses boundary at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-processing-payload" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "          -- rule:hold-delete-processing-payload\n          RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload'\n            USING ERRCODE = '23514';",
                 mutated: "          -- rule:hold-delete-processing-payload\n          NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_processing_payload_mutation",
                 test_name: "plain: hold delete refuses processing_payload at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name:
                       "plain: hold delete refuses processing_payload at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses processing_payload at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-retention" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:hold-delete-retention\n        RAISE EXCEPTION 'idempotency claim is inside its retention horizon'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:hold-delete-retention\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_retention_mutation",
                 test_name: "plain: hold delete refuses retention at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: hold delete refuses retention at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses retention at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-count-before" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:hold-delete-count-before\n        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:hold-delete-count-before\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_count_before_mutation",
                 test_name: "plain: hold delete refuses count_before at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: hold delete refuses count_before at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses count_before at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-count-after" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:hold-delete-count-after\n        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:hold-delete-count-after\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_count_after_mutation",
                 test_name: "plain: hold delete refuses count_after at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: hold delete refuses count_after at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses count_after at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-delete-held" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:hold-delete-held\n        RAISE EXCEPTION 'held idempotency claim cannot be deleted; release its operation hold first'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:hold-delete-held\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_delete_held_mutation",
                 test_name: "plain: hold delete refuses held at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: hold delete refuses held at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: hold delete refuses held at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "previous-delete-unarmed" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "          -- rule:previous-delete-unarmed\n          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'\n            USING ERRCODE = '23514';",
                 mutated: "          -- rule:previous-delete-unarmed\n          NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_delete_unarmed_mutation",
                 test_name: "plain: previous delete refuses unarmed at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: previous delete refuses unarmed at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: previous delete refuses unarmed at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "previous-delete-boundary" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "          -- rule:previous-delete-boundary\n          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'\n            USING ERRCODE = '23514';",
                 mutated: "          -- rule:previous-delete-boundary\n          NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_delete_boundary_mutation",
                 test_name: "plain: previous delete refuses boundary at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: previous delete refuses boundary at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: previous delete refuses boundary at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "previous-delete-processing-payload" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "          -- rule:previous-delete-processing-payload\n          RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload'\n            USING ERRCODE = '23514';",
                 mutated: "          -- rule:previous-delete-processing-payload\n          NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_delete_processing_payload_mutation",
                 test_name:
                   "plain: previous delete refuses processing_payload at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name:
                       "plain: previous delete refuses processing_payload at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name:
                       "2: previous delete refuses processing_payload at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "previous-delete-retention" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:previous-delete-retention\n        RAISE EXCEPTION 'idempotency claim is inside its retention horizon'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:previous-delete-retention\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_delete_retention_mutation",
                 test_name: "plain: previous delete refuses retention at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: previous delete refuses retention at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: previous delete refuses retention at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "previous-delete-count-before" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:previous-delete-count-before\n        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:previous-delete-count-before\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_delete_count_before_mutation",
                 test_name: "plain: previous delete refuses count_before at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: previous delete refuses count_before at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: previous delete refuses count_before at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "previous-delete-count-after" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:previous-delete-count-after\n        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'\n          USING ERRCODE = '23514';",
                 mutated: "        -- rule:previous-delete-count-after\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_delete_count_after_mutation",
                 test_name: "plain: previous delete refuses count_after at its owning guard",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: previous delete refuses count_after at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: previous delete refuses count_after at its owning guard",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "hold-cleanup-arguments" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:hold-cleanup-arguments\n        RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';",
                 mutated: "        -- rule:hold-cleanup-arguments\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_cleanup_arguments_mutation",
                 test_name: "plain: hold cleanup refuses a zero batch",
                 assertion: "assert",
                 assertion_line: 139,
                 required_failures: [
                   %{
                     test_name: "plain: hold cleanup refuses a zero batch",
                     assertion: "assert",
                     assertion_line: 139
                   },
                   %{
                     test_name: "2: hold cleanup refuses a zero batch",
                     assertion: "assert",
                     assertion_line: 139
                   }
                 ]
               },
               "hold-cleanup-row-lock" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:hold-cleanup-row-lock\n        FOR UPDATE SKIP LOCKED",
                 mutated:
                   "        -- rule:hold-cleanup-row-lock\n        FOR NO KEY UPDATE SKIP LOCKED",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_hold_cleanup_row_lock_mutation",
                 test_name: "plain: hold cleanup skips a held KEY SHARE",
                 assertion: "assert",
                 assertion_line: 182,
                 required_failures: [
                   %{
                     test_name: "plain: hold cleanup skips a held KEY SHARE",
                     assertion: "assert",
                     assertion_line: 182
                   },
                   %{
                     test_name: "2: hold cleanup skips a held KEY SHARE",
                     assertion: "assert",
                     assertion_line: 182
                   }
                 ]
               },
               "previous-cleanup-arguments" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:previous-cleanup-arguments\n        RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';",
                 mutated: "        -- rule:previous-cleanup-arguments\n        NULL;",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_cleanup_arguments_mutation",
                 test_name: "plain: previous cleanup refuses a zero batch",
                 assertion: "assert",
                 assertion_line: 139,
                 required_failures: [
                   %{
                     test_name: "plain: previous cleanup refuses a zero batch",
                     assertion: "assert",
                     assertion_line: 139
                   },
                   %{
                     test_name: "2: previous cleanup refuses a zero batch",
                     assertion: "assert",
                     assertion_line: 139
                   }
                 ]
               },
               "previous-cleanup-row-lock" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "        -- rule:previous-cleanup-row-lock\n        FOR UPDATE SKIP LOCKED",
                 mutated:
                   "        -- rule:previous-cleanup-row-lock\n        FOR NO KEY UPDATE SKIP LOCKED",
                 test: "test/ash_onetime/external_state/delete_guards_test.exs",
                 tag: "enforcement_previous_cleanup_row_lock_mutation",
                 test_name: "plain: previous cleanup skips a held KEY SHARE",
                 assertion: "assert",
                 assertion_line: 182,
                 required_failures: [
                   %{
                     test_name: "plain: previous cleanup skips a held KEY SHARE",
                     assertion: "assert",
                     assertion_line: 182
                   },
                   %{
                     test_name: "2: previous cleanup skips a held KEY SHARE",
                     assertion: "assert",
                     assertion_line: 182
                   }
                 ]
               },
               "external-reference-invoker" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "SECURITY INVOKER\n",
                 mutated: "SECURITY DEFINER\n",
                 test: "test/ash_onetime/external_state/upgrade_routine_attributes_test.exs",
                 tag: "enforcement_external_reference_invoker_mutation",
                 test_name: "plain: temporary reference routines execute as their caller",
                 assertion: "assert",
                 assertion_line: 81,
                 required_failures: [
                   %{
                     test_name: "plain: temporary reference routines execute as their caller",
                     assertion: "assert",
                     assertion_line: 81
                   },
                   %{
                     test_name: "2: temporary reference routines execute as their caller",
                     assertion: "assert",
                     assertion_line: 81
                   }
                 ]
               },
               "external-reference-search-path" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "SET search_path=pg_catalog,pg_temp AS %L",
                 mutated: "SET search_path=public AS %L",
                 test: "test/ash_onetime/external_state/upgrade_routine_attributes_test.exs",
                 tag: "enforcement_external_reference_search_path_mutation",
                 test_name: "plain: temporary reference routines fix their search path",
                 assertion: "assert",
                 assertion_line: 98,
                 required_failures: [
                   %{
                     test_name: "plain: temporary reference routines fix their search path",
                     assertion: "assert",
                     assertion_line: 98
                   },
                   %{
                     test_name: "2: temporary reference routines fix their search path",
                     assertion: "assert",
                     assertion_line: 98
                   }
                 ]
               },
               "external-routine-security" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE %s %s SECURITY %s %s AS %L',",
                 mutated:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE %s %s /* %s */ %s AS %L',",
                 test: "test/ash_onetime/external_state/upgrade_routine_attributes_test.exs",
                 tag: "enforcement_external_routine_security_mutation",
                 test_name:
                   "plain: the upgraded outcome guard retains its declared definer authority",
                 assertion: "assert",
                 assertion_line: 104,
                 required_failures: [
                   %{
                     test_name:
                       "plain: the upgraded outcome guard retains its declared definer authority",
                     assertion: "assert",
                     assertion_line: 104
                   },
                   %{
                     test_name:
                       "2: the upgraded outcome guard retains its declared definer authority",
                     assertion: "assert",
                     assertion_line: 104
                   }
                 ]
               },
               "install-shapes-invoker" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_shapes() RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER %s AS %L',",
                 mutated:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_shapes() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER %s AS %L',",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_install_shapes_invoker_mutation",
                 test_name: "plain: ash_onetime_maintenance_shapes fixes install-shapes-invoker",
                 assertion: "assert",
                 assertion_line: 32,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_maintenance_shapes fixes install-shapes-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   },
                   %{
                     test_name: "2: ash_onetime_maintenance_shapes fixes install-shapes-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   }
                 ]
               },
               "install-policy-invoker" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_policy_error() RETURNS text LANGUAGE plpgsql SECURITY INVOKER %s AS %L',",
                 mutated:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_policy_error() RETURNS text LANGUAGE plpgsql SECURITY DEFINER %s AS %L',",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_install_policy_invoker_mutation",
                 test_name:
                   "plain: ash_onetime_maintenance_policy_error fixes install-policy-invoker",
                 assertion: "assert",
                 assertion_line: 32,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_maintenance_policy_error fixes install-policy-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   },
                   %{
                     test_name:
                       "2: ash_onetime_maintenance_policy_error fixes install-policy-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   }
                 ]
               },
               "install-trust-invoker" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_trust() RETURNS void LANGUAGE plpgsql SECURITY INVOKER %s AS %L',",
                 mutated:
                   "EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_trust() RETURNS void LANGUAGE plpgsql SECURITY DEFINER %s AS %L',",
                 test: "test/ash_onetime/external_state/routine_attributes_test.exs",
                 tag: "enforcement_install_trust_invoker_mutation",
                 test_name: "plain: ash_onetime_maintenance_trust fixes install-trust-invoker",
                 assertion: "assert",
                 assertion_line: 32,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ash_onetime_maintenance_trust fixes install-trust-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   },
                   %{
                     test_name: "2: ash_onetime_maintenance_trust fixes install-trust-invoker",
                     assertion: "assert",
                     assertion_line: 32
                   }
                 ]
               },
               "query-classify-privilege" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}) do\n    # Per-child prune failures become kept/refused outcomes inside the owner-owned routine.\n    # A privilege failure reaching this classifier is an ordinary store-query failure.\n    Result.failure(:store_invariant, :sent, :rolled_back)",
                 test: ["test/ash_onetime/external_state/query_classification_test.exs"],
                 tag: "enforcement_query_classify_privilege_mutation",
                 test_name:
                   "plain: SQLSTATE 42501 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 42501 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 42501 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}) do\n    # Per-child prune failures become kept/refused outcomes inside the owner-owned routine.\n    # A privilege failure reaching this classifier is an ordinary store-query failure.\n    Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-lock" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{code: code}})\n       when code in [:lock_not_available, :lock_timeout] do\n    Result.failure(:lock_timeout, :sent, :rolled_back)",
                 test: ["test/ash_onetime/external_state/query_classification_test.exs"],
                 tag: "enforcement_query_classify_lock_mutation",
                 test_name:
                   "plain: SQLSTATE 55P03 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 55P03 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 55P03 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{code: code}})\n       when code in [:lock_not_available, :lock_timeout] do\n    Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-completion-unknown" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: \"40003\"}}) do\n    Result.failure(:dispatched_unknown, :unknown, :unknown)",
                 test: ["test/ash_onetime/external_state/query_classification_test.exs"],
                 tag: "enforcement_query_classify_completion_unknown_mutation",
                 test_name:
                   "plain: SQLSTATE 40003 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 40003 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 40003 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: \"40003\"}}) do\n    Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-connection" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: <<\"08\", _::binary>>}}),\n    do: Result.failure(:disconnected, :unknown, :unknown)",
                 test: ["test/ash_onetime/external_state/query_classification_test.exs"],
                 tag: "enforcement_query_classify_connection_mutation",
                 test_name:
                   "plain: SQLSTATE 08006 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 08006 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 08006 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: <<\"08\", _::binary>>}}),\n    do: Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-shutdown" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: <<\"57P\", _::binary>>}}),\n    do: Result.failure(:disconnected, :unknown, :unknown)",
                 test: [
                   "test/ash_onetime/external_state/query_classification_test.exs",
                   "test/ash_onetime/external_state/post_dispatch_failure_test.exs"
                 ],
                 tag: "enforcement_query_classify_shutdown_mutation",
                 test_name:
                   "plain: SQLSTATE 57P01 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 57P01 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 57P01 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: <<\"57P\", _::binary>>}}),\n    do: Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-idle" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: \"25P03\"}}),\n    do: Result.failure(:disconnected, :unknown, :unknown)",
                 test: [
                   "test/ash_onetime/external_state/query_classification_test.exs",
                   "test/ash_onetime/external_state/post_dispatch_failure_test.exs"
                 ],
                 tag: "enforcement_query_classify_idle_mutation",
                 test_name:
                   "plain: SQLSTATE 25P03 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 25P03 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 25P03 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: \"25P03\"}}),\n    do: Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-transient" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: pg_code}})\n       when pg_code == \"57014\" or binary_part(pg_code, 0, 2) in [\"40\", \"53\", \"58\"] do\n    Result.failure(:store_failure, :sent, :rolled_back)",
                 test: ["test/ash_onetime/external_state/query_classification_test.exs"],
                 tag: "enforcement_query_classify_transient_mutation",
                 test_name:
                   "plain: SQLSTATE 40001 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 40001 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 40001 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{postgres: %{pg_code: pg_code}})\n       when pg_code == \"57014\" or binary_part(pg_code, 0, 2) in [\"40\", \"53\", \"58\"] do\n    Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "query-classify-postgres-other" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%Postgrex.Error{}) do\n    Result.failure(:store_invariant, :sent, :rolled_back)",
                 test: ["test/ash_onetime/external_state/query_classification_test.exs"],
                 tag: "enforcement_query_classify_postgres_other_mutation",
                 test_name:
                   "plain: SQLSTATE 23514 retains its dispatch and transaction classification",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: SQLSTATE 23514 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   },
                   %{
                     test_name:
                       "2: SQLSTATE 23514 retains its dispatch and transaction classification",
                     assertion_line: 52,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp classify_query_error(%Postgrex.Error{}) do\n    Result.failure(:invalid_request, :not_started, :not_applicable)",
                 assertion: "assert"
               },
               "effect-classify-local" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp effect_state(%Claim{effect_local: true}, _), do: :local",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_local_mutation",
                 test_name: "plain: the loaded claim classifies local",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies local",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies local",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp effect_state(%Claim{effect_local: true}, _), do: :invalid_request",
                 assertion: "assert"
               },
               "effect-classify-resolved" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp effect_state(%Claim{state: :complete, effect_attempt: 0}, _), do: :resolved",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_resolved_mutation",
                 test_name: "plain: the loaded claim classifies resolved",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies resolved",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies resolved",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated:
                   "defp effect_state(%Claim{state: :complete, effect_attempt: 0}, _), do: :invalid_request",
                 assertion: "assert"
               },
               "effect-classify-finalized" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp effect_state(%Claim{state: :complete}, _), do: :finalized",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_finalized_mutation",
                 test_name: "plain: the loaded claim classifies finalized",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies finalized",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies finalized",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated: "defp effect_state(%Claim{state: :complete}, _), do: :invalid_request",
                 assertion: "assert"
               },
               "effect-classify-unknown" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp effect_state(%Claim{effect_attempt: 0}, _), do: :unknown",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_unknown_mutation",
                 test_name: "plain: the loaded claim classifies unknown",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies unknown",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies unknown",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated: "defp effect_state(%Claim{effect_attempt: 0}, _), do: :invalid_request",
                 assertion: "assert"
               },
               "effect-classify-held" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp effect_state(_claim, \"held\"), do: :held",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_held_mutation",
                 test_name: "plain: the loaded claim classifies held",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies held",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies held",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated: "defp effect_state(_claim, \"held\"), do: :invalid_request",
                 assertion: "assert"
               },
               "effect-classify-absent-proven" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp effect_state(_claim, \"absent_proven\"), do: :absent_proven",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_absent_proven_mutation",
                 test_name: "plain: the loaded claim classifies absent_proven",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies absent_proven",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies absent_proven",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated: "defp effect_state(_claim, \"absent_proven\"), do: :invalid_request",
                 assertion: "assert"
               },
               "effect-classify-unresolved" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp effect_state(_claim, _), do: :unresolved",
                 test: ["test/ash_onetime/external_state/effect_classification_test.exs"],
                 tag: "enforcement_effect_classify_unresolved_mutation",
                 test_name: "plain: the loaded claim classifies unresolved",
                 assertion_line: 22,
                 required_failures: [
                   %{
                     test_name: "plain: the loaded claim classifies unresolved",
                     assertion_line: 22,
                     assertion: "assert"
                   },
                   %{
                     test_name: "2: the loaded claim classifies unresolved",
                     assertion_line: 22,
                     assertion: "assert"
                   }
                 ],
                 mutated: "defp effect_state(_claim, _), do: :invalid_request",
                 assertion: "assert"
               },
               "classifier-outcome" => %{
                 path: "lib/ash_onetime/response_classifier.ex",
                 original:
                   "{outcome, classified} when outcome in [:store, :reject, :rollback] ->\n        {outcome, classified}",
                 test: ["test/ash_onetime/response_classifier_test.exs"],
                 tag: "enforcement_classifier_outcome_mutation",
                 test_name: "accepts only the three closed outcomes",
                 assertion_line: 18,
                 mutated:
                   "{outcome, classified} when outcome in [:store, :reject, :rollback] ->\n        {:rollback, classified}",
                 assertion: "assert"
               },
               "classifier-invalid" => %{
                 path: "lib/ash_onetime/response_classifier.ex",
                 original:
                   "_other ->\n        {:error,\n         Error.new(\n           :response_classifier_invalid,",
                 test: ["test/ash_onetime/response_classifier_test.exs"],
                 tag: "enforcement_classifier_invalid_mutation",
                 test_name: "malformed output and boundary failures are value-free typed errors",
                 assertion_line: 25,
                 mutated:
                   "_other ->\n        {:error,\n         Error.new(\n           :response_classifier_failed,",
                 assertion: "assert"
               },
               "classifier-rescue" => %{
                 path: "lib/ash_onetime/response_classifier.ex",
                 original:
                   "_exception ->\n      {:error, Error.new(:response_classifier_failed, \"response classifier failed\")}",
                 test: ["test/ash_onetime/response_classifier_test.exs"],
                 tag: "enforcement_classifier_invalid_mutation",
                 test_name: "malformed output and boundary failures are value-free typed errors",
                 assertion_line: 28,
                 mutated:
                   "_exception ->\n      {:error, Error.new(:response_classifier_invalid, \"response classifier failed\")}",
                 assertion: "assert"
               },
               "classifier-catch" => %{
                 path: "lib/ash_onetime/response_classifier.ex",
                 original:
                   "_kind, _reason ->\n      {:error, Error.new(:response_classifier_failed, \"response classifier failed\")}",
                 test: ["test/ash_onetime/response_classifier_test.exs"],
                 tag: "enforcement_classifier_catch_mutation",
                 test_name:
                   "a throwing or exiting classifier fails closed without leaking the value",
                 assertion_line: 35,
                 mutated:
                   "_kind, _reason ->\n      {:error, Error.new(:response_classifier_invalid, \"response classifier failed\")}",
                 assertion: "assert"
               },
               "classifier-fallback" => %{
                 path: "lib/ash_onetime/response_classifier.ex",
                 original:
                   "def classify(_classifier, _value, _context) do\n    {:error, Error.new(:response_classifier_invalid, \"response classifier is invalid\")}",
                 test: ["test/ash_onetime/response_classifier_test.exs"],
                 tag: "enforcement_classifier_fallback_mutation",
                 test_name: "a non-atom classifier fails closed",
                 assertion_line: 50,
                 mutated:
                   "def classify(_classifier, _value, _context) do\n    {:error, Error.new(:response_classifier_failed, \"response classifier is invalid\")}",
                 assertion: "assert"
               },
               "logical-column-check" => %{
                 path: "priv/templates/migrations/logical_partitions.exs",
                 original: "CHECK (octet_length(logical_partition) BETWEEN 1 AND 255)",
                 mutated: "CHECK (true)",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_logical_column_check_mutation",
                 test_name: "plain: logical-column-check refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: logical-column-check refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name: "2: logical-column-check refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "logical-downgrade-refusal" => %{
                 path: "priv/templates/migrations/logical_partitions.exs",
                 original:
                   "RAISE EXCEPTION 'cannot remove logical partitions while non-global claims exist'\n          USING ERRCODE = '23514';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_logical_downgrade_refusal_mutation",
                 test_name:
                   "plain: logical-downgrade-refusal refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: logical-downgrade-refusal refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name:
                       "2: logical-downgrade-refusal refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "logical-collision-required" => %{
                 path: "priv/templates/migrations/logical_partitions.exs",
                 original:
                   "RAISE EXCEPTION 'legacy ash_onetime collision constraint is missing'\n          USING ERRCODE = '23514';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_logical_collision_required_mutation",
                 test_name:
                   "plain: logical-collision-required refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: logical-collision-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name:
                       "2: logical-collision-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "operation-hold-check" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "CHECK (hold_reference IS NULL OR (octet_length(hold_reference) >= 1 AND octet_length(hold_reference) <= 255 AND state = 'complete')) NOT VALID",
                 mutated: "CHECK (true) NOT VALID",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_operation_hold_check_mutation",
                 test_name: "plain: operation-hold-check refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: operation-hold-check refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name: "2: operation-hold-check refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "operation-hold-rollback-held" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "RAISE EXCEPTION 'release operation holds before removing operation-hold support' USING ERRCODE = '23514';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_operation_hold_rollback_held_mutation",
                 test_name:
                   "plain: operation-hold-rollback-held refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: operation-hold-rollback-held refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name:
                       "2: operation-hold-rollback-held refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "operation-hold-rollback-unresolved" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "IF unresolved THEN RAISE EXCEPTION 'unresolved external claims prevent rollback' USING ERRCODE='23514'; END IF;",
                 mutated: "IF unresolved THEN NULL; END IF;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_operation_hold_rollback_unresolved_mutation",
                 test_name:
                   "plain: operation-hold-rollback-unresolved refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: operation-hold-rollback-unresolved refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name:
                       "2: operation-hold-rollback-unresolved refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "external-hold-required" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "RAISE EXCEPTION 'operation_hold_required: apply operation-hold before external-state';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_external_hold_required_mutation",
                 test_name: "plain: external-hold-required refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external-hold-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name: "2: external-hold-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "maintenance-hold-required" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'operation_hold_required: apply the 2.0 operation-hold migration first';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_maintenance_hold_required_mutation",
                 test_name:
                   "plain: maintenance-hold-required refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-hold-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name:
                       "2: maintenance-hold-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "maintenance-external-required" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'untrusted_dependency: upgrade relation shape ash_onetime_idempotency_claims';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_maintenance_external_required_mutation",
                 test_name:
                   "plain: maintenance-external-required refuses at its owning migration guard",
                 assertion: "assert_raise Postgrex.Error",
                 assertion_line: 142,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-external-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   },
                   %{
                     test_name:
                       "2: maintenance-external-required refuses at its owning migration guard",
                     assertion: "assert_raise Postgrex.Error",
                     assertion_line: 142
                   }
                 ]
               },
               "upgrade-enable-claim-delete" => %{
                 path: "priv/templates/migrations/operation_hold.exs",
                 original:
                   "execute(\"ALTER TABLE \#{q(@claims)} ENABLE ALWAYS TRIGGER ash_onetime_idempotency_delete_guard\")",
                 mutated:
                   "execute(\"ALTER TABLE \#{q(@claims)} ENABLE TRIGGER ash_onetime_idempotency_delete_guard\")",
                 test: "test/ash_onetime/external_state/migration_guards_test.exs",
                 tag: "enforcement_upgrade_enable_claim_delete_mutation",
                 test_name:
                   "plain: the hold upgrade activates the claim guard in every replication mode",
                 assertion: "assert",
                 assertion_line: 165,
                 required_failures: [
                   %{
                     test_name:
                       "plain: the hold upgrade activates the claim guard in every replication mode",
                     assertion: "assert",
                     assertion_line: 165
                   },
                   %{
                     test_name:
                       "2: the hold upgrade activates the claim guard in every replication mode",
                     assertion: "assert",
                     assertion_line: 165
                   }
                 ]
               },
               "loaded-processing" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp loaded_result(_target, %Claim{strategy: :idempotency, state: :processing} = claim) do\n    {:ok, Result.success(:processing, claim: claim)}",
                 mutated:
                   "defp loaded_result(_target, %Claim{strategy: :idempotency, state: :processing} = claim) do\n    {:ok, Result.success(:collision, claim: claim)}",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: load classifies processing from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: load classifies processing from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: load classifies processing from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "loaded-expired" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "{:ok, Result.success(:complete_expired, claim: claim)}",
                 mutated: "{:ok, Result.success(:processing, claim: claim)}",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: load classifies expired from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: load classifies expired from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: load classifies expired from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "loaded-complete" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "{:ok, Result.success(:complete, claim: claim, payload: payload)}",
                 mutated: "{:ok, Result.success(:processing, claim: claim, payload: payload)}",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: load classifies complete from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: load classifies complete from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: load classifies complete from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "loaded-corrupt" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "else\n      {:error, Result.failure(:corrupt_payload, :sent, :open)}",
                 mutated: "else\n      {:error, Result.failure(:store_invariant, :sent, :open)}",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: load classifies corrupt from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: load classifies corrupt from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: load classifies corrupt from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "loaded-nonce" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp loaded_result(_target, %Claim{strategy: :one_time_nonce} = claim) do\n    {:ok, Result.success(:collision, claim: claim)}",
                 mutated:
                   "defp loaded_result(_target, %Claim{strategy: :one_time_nonce} = claim) do\n    {:ok, Result.success(:processing, claim: claim)}",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: load classifies nonce from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: load classifies nonce from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: load classifies nonce from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "loaded-invalid" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp loaded_result(_target, _claim) do\n    {:error, Result.failure(:store_invariant, :sent, :open)}",
                 mutated:
                   "defp loaded_result(_target, _claim) do\n    {:error, Result.failure(:corrupt_payload, :sent, :open)}",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: load classifies invalid from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: load classifies invalid from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: load classifies invalid from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "collision-nonce" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp collision_result(_target, %Claim{strategy: :one_time_nonce} = claim),\n    do: Result.success(:collision, claim: claim)",
                 mutated:
                   "defp collision_result(_target, %Claim{strategy: :one_time_nonce} = claim),\n    do: Result.success(:processing, claim: claim)",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: collision classifies nonce from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: collision classifies nonce from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: collision classifies nonce from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "collision-loaded-success" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "case loaded_result(target, claim) do\n      {:ok, %Result{} = result} -> result",
                 mutated:
                   "case loaded_result(target, claim) do\n      {:ok, %Result{} = _result} -> Result.failure(:store_invariant, :sent, :open)",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: collision classifies complete from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: collision classifies complete from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: collision classifies complete from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "collision-loaded-failure" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "{:error, %Result{} = failure} -> failure",
                 mutated:
                   "{:error, %Result{} = _failure} -> Result.failure(:corrupt_payload, :sent, :open)",
                 test: "test/ash_onetime/external_state/loaded_classification_test.exs",
                 tag: "enforcement_loaded_classification_mutation",
                 test_name: "plain: collision classifies invalid from authoritative state",
                 assertion: "assert",
                 assertion_line: 100,
                 required_failures: [
                   %{
                     test_name: "plain: collision classifies invalid from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   },
                   %{
                     test_name: "2: collision classifies invalid from authoritative state",
                     assertion: "assert",
                     assertion_line: 100
                   }
                 ]
               },
               "install-upgrade-policy-policy" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "CREATE POLICY ash_onetime_upgrade_policy ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())",
                 mutated:
                   "CREATE POLICY ash_onetime_upgrade_policy ON %s AS RESTRICTIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_install_upgrade_policy_policy_mutation",
                 test_name:
                   "plain: install-upgrade-policy-policy preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-upgrade-policy-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: install-upgrade-policy-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "install-upgrade-policy-check" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "-- rule:install-upgrade-policy-check\n        WITH CHECK (%I.ash_onetime_maintenance_active())",
                 mutated:
                   "-- rule:install-upgrade-policy-check\n        WITH CHECK (false /* %I */)",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_install_upgrade_policy_check_mutation",
                 test_name:
                   "plain: install-upgrade-policy-check preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-upgrade-policy-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: install-upgrade-policy-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "install-maintenance-policy" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "CREATE POLICY ash_onetime_maintenance ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())",
                 mutated:
                   "CREATE POLICY ash_onetime_maintenance ON %s AS RESTRICTIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_install_maintenance_policy_mutation",
                 test_name:
                   "plain: install-maintenance-policy preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-maintenance-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: install-maintenance-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "install-maintenance-check" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "-- rule:install-maintenance-check\n        WITH CHECK (%I.ash_onetime_maintenance_active())",
                 mutated:
                   "-- rule:install-maintenance-check\n        WITH CHECK (false /* %I */)",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_install_maintenance_check_mutation",
                 test_name:
                   "plain: install-maintenance-check preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-maintenance-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: install-maintenance-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "install-claim-visibility-policy" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "CREATE POLICY ash_onetime_claim_visibility ON %s AS PERMISSIVE FOR ALL TO PUBLIC USING (%I.ash_onetime_claim_visible(%sclaim_id))",
                 mutated:
                   "CREATE POLICY ash_onetime_claim_visibility ON %s AS RESTRICTIVE FOR ALL TO PUBLIC USING (%I.ash_onetime_claim_visible(%sclaim_id))",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_install_claim_visibility_policy_mutation",
                 test_name:
                   "plain: install-claim-visibility-policy preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-claim-visibility-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: install-claim-visibility-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "install-claim-visibility-check" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original: "WITH CHECK (%I.ash_onetime_claim_visible(%sclaim_id))",
                 mutated: "WITH CHECK (false /* %I %s */)",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_install_claim_visibility_check_mutation",
                 test_name:
                   "plain: install-claim-visibility-check preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-claim-visibility-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: install-claim-visibility-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "external-maintenance-policy" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "CREATE POLICY ash_onetime_maintenance ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())",
                 mutated:
                   "CREATE POLICY ash_onetime_maintenance ON %s AS RESTRICTIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_external_maintenance_policy_mutation",
                 test_name:
                   "plain: external-maintenance-policy preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external-maintenance-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: external-maintenance-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "external-maintenance-check" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "WITH CHECK (%I.ash_onetime_maintenance_active())",
                 mutated: "WITH CHECK (false /* %I */)",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_external_maintenance_check_mutation",
                 test_name:
                   "plain: external-maintenance-check preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external-maintenance-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: external-maintenance-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "external-claim-visibility-policy" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "CREATE POLICY ash_onetime_claim_visibility ON %s AS PERMISSIVE FOR ALL TO PUBLIC USING (%I.ash_onetime_claim_visible(%sclaim_id))",
                 mutated:
                   "CREATE POLICY ash_onetime_claim_visibility ON %s AS RESTRICTIVE FOR ALL TO PUBLIC USING (%I.ash_onetime_claim_visible(%sclaim_id))",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_external_claim_visibility_policy_mutation",
                 test_name:
                   "plain: external-claim-visibility-policy preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external-claim-visibility-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: external-claim-visibility-policy preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "external-claim-visibility-check" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "WITH CHECK (%I.ash_onetime_claim_visible(%sclaim_id))",
                 mutated: "WITH CHECK (false /* %I %s */)",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_external_claim_visibility_check_mutation",
                 test_name:
                   "plain: external-claim-visibility-check preserves its native policy attribute",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external-claim-visibility-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: external-claim-visibility-check preserves its native policy attribute",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "copy-policy-check" => %{
                 path: "priv/templates/migrations/maintenance/copy_policy.sql",
                 original:
                   "CASE WHEN policy.polwithcheck IS NULL THEN '' ELSE ' WITH CHECK (' || pg_get_expr(policy.polwithcheck,policy.polrelid) || ')' END)",
                 mutated:
                   "CASE WHEN policy.polwithcheck IS NULL THEN '' ELSE ' WITH CHECK (false)' END)",
                 test: "test/ash_onetime/external_state/policy_sites_test.exs",
                 tag: "enforcement_copy_policy_check_mutation",
                 test_name: "plain: copying a policy preserves its explicit write check",
                 assertion: "assert",
                 assertion_line: 141,
                 required_failures: [
                   %{
                     test_name: "plain: copying a policy preserves its explicit write check",
                     assertion: "assert",
                     assertion_line: 141
                   },
                   %{
                     test_name: "2: copying a policy preserves its explicit write check",
                     assertion: "assert",
                     assertion_line: 141
                   }
                 ]
               },
               "trust-relation-shape-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original:
                   "RAISE EXCEPTION 'untrusted_dependency: relation shape %',relation_row.relname;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/trust_guards_test.exs",
                 tag: "enforcement_trust_relation_shape_refusal_mutation",
                 test_name:
                   "plain: trust-relation-shape-refusal reports its owning trust refusal",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name:
                       "plain: trust-relation-shape-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name:
                       "2: trust-relation-shape-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name:
                       "2: trust rejects a changed hash bound through the native child shape",
                     assertion: "assert",
                     assertion_line: 185
                   }
                 ]
               },
               "trust-policy-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original:
                   "IF policy_error IS NOT NULL THEN RAISE EXCEPTION 'maintenance_blinded: %',policy_error; END IF;",
                 mutated: "IF policy_error IS NOT NULL THEN NULL; END IF;",
                 test: "test/ash_onetime/external_state/trust_guards_test.exs",
                 tag: "enforcement_trust_policy_refusal_mutation",
                 test_name: "plain: trust-policy-refusal reports its owning trust refusal",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: trust-policy-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: trust-policy-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "trust-authority-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original:
                   "RAISE EXCEPTION 'untrusted_dependency: effective % privilege%',authority_error,\n      CASE WHEN authority_error='replication' THEN ' for role ' || authority_holder ELSE '' END;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/trust_guards_test.exs",
                 tag: "enforcement_trust_authority_refusal_mutation",
                 test_name: "plain: trust-authority-refusal reports its owning trust refusal",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name: "plain: trust-authority-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: trust-authority-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "trust-helper-public-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original:
                   "RAISE EXCEPTION 'untrusted_dependency: ash_onetime_claim_visible missing PUBLIC EXECUTE';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/trust_guards_test.exs",
                 tag: "enforcement_trust_helper_public_refusal_mutation",
                 test_name: "plain: trust-helper-public-refusal reports its owning trust refusal",
                 assertion: "assert",
                 assertion_line: 126,
                 required_failures: [
                   %{
                     test_name:
                       "plain: trust-helper-public-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 126
                   },
                   %{
                     test_name: "2: trust-helper-public-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 126
                   }
                 ]
               },
               "trust-package-acl-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original: "RAISE EXCEPTION 'untrusted_dependency: package ACL';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/trust_guards_test.exs",
                 tag: "enforcement_trust_package_acl_refusal_mutation",
                 test_name: "plain: trust-package-acl-refusal reports its owning trust refusal",
                 assertion: "assert",
                 assertion_line: 119,
                 required_failures: [
                   %{
                     test_name:
                       "plain: trust-package-acl-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   },
                   %{
                     test_name: "2: trust-package-acl-refusal reports its owning trust refusal",
                     assertion: "assert",
                     assertion_line: 119
                   }
                 ]
               },
               "trust-partition-date-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original: "RAISE EXCEPTION 'untrusted_dependency: partition date range';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/trust_guards_test.exs",
                 tag: "enforcement_trust_partition_date_refusal_mutation",
                 test_name:
                   "plain: trust-partition-date-refusal reports its owning trust refusal",
                 assertion: "assert String.starts_with?(message, @message)",
                 assertion_line: 126,
                 required_failures: [
                   %{
                     test_name:
                       "plain: trust-partition-date-refusal reports its owning trust refusal",
                     assertion: "assert String.starts_with?(message, @message)",
                     assertion_line: 126
                   },
                   %{
                     test_name:
                       "2: trust-partition-date-refusal reports its owning trust refusal",
                     assertion: "assert String.starts_with?(message, @message)",
                     assertion_line: 126
                   }
                 ]
               },
               "maintenance-classify-arguments" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{pg_code: \"22023\"}}),\n    do: Result.failure(:invalid_request, :sent, :rolled_back)",
                 mutated:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{pg_code: \"22023\"}}),\n    do: Result.failure(:dispatched_unknown, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_arguments_mutation",
                 test_name:
                   "plain: maintenance-classify-arguments retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-arguments retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-arguments retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-timeout" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{pg_code: \"57014\"}}),\n    do: Result.failure(:maintenance_timeout, :sent, :rolled_back)",
                 mutated:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{pg_code: \"57014\"}}),\n    do: Result.failure(:dispatched_unknown, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_timeout_mutation",
                 test_name:
                   "plain: maintenance-classify-timeout retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-timeout retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-timeout retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-lock" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{pg_code: \"55P03\"}}),\n    do: Result.failure(:lock_unavailable, :sent, :rolled_back)",
                 mutated:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{pg_code: \"55P03\"}}),\n    do: Result.failure(:dispatched_unknown, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_lock_mutation",
                 test_name:
                   "plain: maintenance-classify-lock retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-lock retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-lock retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-privilege" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}),\n    do: Result.failure(:maintenance_not_permitted, :sent, :rolled_back)",
                 mutated:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}),\n    do: Result.failure(:dispatched_unknown, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_privilege_mutation",
                 test_name:
                   "plain: maintenance-classify-privilege retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-privilege retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-privilege retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-isolation" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{code: :active_sql_transaction}}),\n    do: Result.failure(:unsupported_isolation, :sent, :rolled_back)",
                 mutated:
                   "defp classify_maintenance_error(%Postgrex.Error{postgres: %{code: :active_sql_transaction}}),\n    do: Result.failure(:dispatched_unknown, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_isolation_mutation",
                 test_name:
                   "plain: maintenance-classify-isolation retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-isolation retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-isolation retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-blinded" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "String.starts_with?(message, \"maintenance_blinded:\") -> :maintenance_blinded",
                 mutated:
                   "String.starts_with?(message, \"maintenance_blinded:\") -> :invalid_request",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_blinded_mutation",
                 test_name:
                   "plain: maintenance-classify-blinded retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-blinded retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-blinded retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-dependency" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "String.starts_with?(message, \"untrusted_dependency:\") -> :untrusted_dependency",
                 mutated:
                   "String.starts_with?(message, \"untrusted_dependency:\") -> :invalid_request",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_dependency_mutation",
                 test_name:
                   "plain: maintenance-classify-dependency retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-dependency retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-dependency retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-blocked" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "String.starts_with?(message, \"prune_blocked:\") -> :prune_blocked",
                 mutated: "String.starts_with?(message, \"prune_blocked:\") -> :invalid_request",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_blocked_mutation",
                 test_name:
                   "plain: maintenance-classify-blocked retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-blocked retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-blocked retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-raised-other" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "true -> :store_invariant",
                 mutated: "true -> :invalid_request",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_raised_other_mutation",
                 test_name:
                   "plain: maintenance-classify-raised-other retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-raised-other retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-raised-other retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-fallback" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_maintenance_error(error), do: classify_query_error(error)",
                 mutated:
                   "defp classify_maintenance_error(_error), do: Result.failure(:invalid_request, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_fallback_mutation",
                 test_name:
                   "plain: maintenance-classify-fallback retains the native maintenance failure",
                 assertion: "assert",
                 assertion_line: 54,
                 required_failures: [
                   %{
                     test_name:
                       "plain: maintenance-classify-fallback retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   },
                   %{
                     test_name:
                       "2: maintenance-classify-fallback retains the native maintenance failure",
                     assertion: "assert",
                     assertion_line: 54
                   }
                 ]
               },
               "maintenance-classify-result" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: "defp classify_maintenance_error(%Result{} = result), do: result",
                 mutated:
                   "defp classify_maintenance_error(%Result{} = result), do: %{result | reason: :invalid_request}",
                 test: "test/ash_onetime/external_state/maintenance_classification_test.exs",
                 tag: "enforcement_maintenance_classify_result_mutation",
                 test_name: "plain: a catalog lookup failure retains its store result",
                 assertion: "assert",
                 assertion_line: 73,
                 required_failures: [
                   %{
                     test_name: "plain: a catalog lookup failure retains its store result",
                     assertion: "assert",
                     assertion_line: 73
                   },
                   %{
                     test_name: "2: a catalog lookup failure retains its store result",
                     assertion: "assert",
                     assertion_line: 73
                   }
                 ]
               },
               "admission-classify-expired-mismatch" => %{
                 original:
                   "# expired fingerprint classification\n      :fingerprint_mismatch ->\n        emit_fingerprint_mismatch(state)\n\n        {:error,\n         Error.new(:key_reused_with_different_request, \"key was reused with a different request\")}",
                 mutated:
                   "# expired fingerprint classification\n      :fingerprint_mismatch ->\n        emit_fingerprint_mismatch(state)\n\n        {:error,\n         Error.new(:store_invariant, \"key was reused with a different request\")}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_expired_mismatch_mutation",
                 test_name:
                   "plain: admission-classify-expired-mismatch resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-expired-mismatch resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-expired-mismatch resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-complete-mismatch" => %{
                 original:
                   "# complete fingerprint classification\n      :fingerprint_mismatch ->\n        emit_fingerprint_mismatch(state)\n\n        {:error,\n         Error.new(:key_reused_with_different_request, \"key was reused with a different request\")}",
                 mutated:
                   "# complete fingerprint classification\n      :fingerprint_mismatch ->\n        emit_fingerprint_mismatch(state)\n\n        {:error,\n         Error.new(:store_invariant, \"key was reused with a different request\")}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_complete_mismatch_mutation",
                 test_name:
                   "plain: admission-classify-complete-mismatch resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-complete-mismatch resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-complete-mismatch resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-processing-mismatch" => %{
                 original:
                   "# processing fingerprint classification\n      :fingerprint_mismatch ->\n        emit_fingerprint_mismatch(state)\n\n        {:error,\n         Error.new(:key_reused_with_different_request, \"key was reused with a different request\")}",
                 mutated:
                   "# processing fingerprint classification\n      :fingerprint_mismatch ->\n        emit_fingerprint_mismatch(state)\n\n        {:error,\n         Error.new(:store_invariant, \"key was reused with a different request\")}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_processing_mismatch_mutation",
                 test_name:
                   "plain: admission-classify-processing-mismatch resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-processing-mismatch resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-processing-mismatch resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-admitted" => %{
                 original: "{:execute, state}",
                 mutated: "{:execute_untracked, state}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_admitted_mutation",
                 test_name: "plain: admission-classify-admitted resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-admitted resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name: "2: admission-classify-admitted resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-processing-local" => %{
                 original: "Error.new(:request_in_progress, \"request is already processing\")",
                 mutated: "Error.new(:store_invariant, \"request is already processing\")",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_processing_local_mutation",
                 test_name:
                   "plain: admission-classify-processing-local resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-processing-local resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-processing-local resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-processing-committed" => %{
                 original: "{:recover, %{state | claim: sanitize_claim(result.claim)}}",
                 mutated: "{:execute, %{state | claim: sanitize_claim(result.claim)}}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_processing_committed_mutation",
                 test_name:
                   "plain: admission-classify-processing-committed resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-processing-committed resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-processing-committed resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-processing-finalize" => %{
                 original:
                   "        :locked_external_finalize ->\n          emit_conflict(state, :processing)\n          {:execute, %{state | class: :external_execute, claim: sanitize_claim(result.claim)}}",
                 mutated:
                   "        :locked_external_finalize ->\n          emit_conflict(state, :processing)\n          {:recover, %{state | class: :external_execute, claim: sanitize_claim(result.claim)}}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_processing_finalize_mutation",
                 test_name:
                   "plain: admission-classify-processing-finalize resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-processing-finalize resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-processing-finalize resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-processing-locked" => %{
                 original:
                   "        :locked_external_claim ->\n          {:execute, %{state | class: :external_execute, claim: sanitize_claim(result.claim)}}",
                 mutated:
                   "        :locked_external_claim ->\n          {:recover, %{state | class: :external_execute, claim: sanitize_claim(result.claim)}}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_processing_locked_mutation",
                 test_name:
                   "plain: admission-classify-processing-locked resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-processing-locked resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-processing-locked resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-complete" => %{
                 original: "{:replay, replayed, replay_state}",
                 mutated: "{:execute, replay_state}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_complete_mutation",
                 test_name: "plain: admission-classify-complete resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-complete resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name: "2: admission-classify-complete resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-expired-invalid" => %{
                 original:
                   "{:error, %Error{} = collision_error} ->\n        {:error, collision_error}",
                 mutated:
                   "{:error, %Error{} = _collision_error} ->\n        {:error, Error.new(:response_expired, \"stored response has expired\")}",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_expired_invalid_mutation",
                 test_name:
                   "plain: admission-classify-expired-invalid resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-expired-invalid resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-expired-invalid resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-nonce" => %{
                 original: "Error.new(:nonce_already_used, \"nonce was already used\")",
                 mutated: "Error.new(:store_invariant, \"nonce was already used\")",
                 path: "lib/ash_onetime/admission.ex",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_nonce_mutation",
                 test_name: "plain: admission-classify-nonce resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name: "plain: admission-classify-nonce resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name: "2: admission-classify-nonce resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "reference-always-delete" => %{
                 path: "priv/templates/migrations/maintenance/reference.sql",
                 original:
                   "EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I',relation_oid::regclass,",
                 mutated:
                   "EXECUTE format('ALTER TABLE %s ENABLE TRIGGER %I',relation_oid::regclass,",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_reference_always_delete_mutation",
                 test_name:
                   "plain: reference-always-delete authenticates the fresh native trigger graph",
                 assertion: "assert reference[root] == actual",
                 assertion_line: 38,
                 required_failures: [
                   %{
                     test_name:
                       "plain: reference-always-delete authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   },
                   %{
                     test_name:
                       "2: reference-always-delete authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   }
                 ]
               },
               "reference-always-claim-update" => %{
                 path: "priv/templates/migrations/maintenance/reference.sql",
                 original:
                   "EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER ash_onetime_idempotency_update_guard',relation_oid::regclass);",
                 mutated:
                   "EXECUTE format('ALTER TABLE %s ENABLE TRIGGER ash_onetime_idempotency_update_guard',relation_oid::regclass);",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_reference_always_claim_update_mutation",
                 test_name:
                   "plain: reference-always-claim-update authenticates the fresh native trigger graph",
                 assertion: "assert reference[root] == actual",
                 assertion_line: 38,
                 required_failures: [
                   %{
                     test_name:
                       "plain: reference-always-claim-update authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   },
                   %{
                     test_name:
                       "2: reference-always-claim-update authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   }
                 ]
               },
               "reference-always-outcome-guard" => %{
                 path: "priv/templates/migrations/maintenance/reference.sql",
                 original:
                   "EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_guard',relation_oid::regclass);",
                 mutated:
                   "EXECUTE format('ALTER TABLE %s ENABLE TRIGGER ash_onetime_effect_outcome_guard',relation_oid::regclass);",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_reference_always_outcome_guard_mutation",
                 test_name:
                   "plain: reference-always-outcome-guard authenticates the fresh native trigger graph",
                 assertion: "assert reference[root] == actual",
                 assertion_line: 38,
                 required_failures: [
                   %{
                     test_name:
                       "plain: reference-always-outcome-guard authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   },
                   %{
                     test_name:
                       "2: reference-always-outcome-guard authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   }
                 ]
               },
               "reference-always-outcome-bound" => %{
                 path: "priv/templates/migrations/maintenance/reference.sql",
                 original:
                   "EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_bound',relation_oid::regclass);",
                 mutated:
                   "EXECUTE format('ALTER TABLE %s ENABLE TRIGGER ash_onetime_effect_outcome_bound',relation_oid::regclass);",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_reference_always_outcome_bound_mutation",
                 test_name:
                   "plain: reference-always-outcome-bound authenticates the fresh native trigger graph",
                 assertion: "assert reference[root] == actual",
                 assertion_line: 38,
                 required_failures: [
                   %{
                     test_name:
                       "plain: reference-always-outcome-bound authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   },
                   %{
                     test_name:
                       "2: reference-always-outcome-bound authenticates the fresh native trigger graph",
                     assertion: "assert reference[root] == actual",
                     assertion_line: 38
                   }
                 ]
               },
               "legacy-reference-always-delete" => %{
                 path: "priv/templates/migrations/maintenance/reference_legacy.sql",
                 original:
                   "EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I',relation_oid::regclass,",
                 mutated:
                   "EXECUTE format('ALTER TABLE %s ENABLE TRIGGER %I',relation_oid::regclass,",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_legacy_reference_always_delete_mutation",
                 test_name:
                   "plain: legacy-reference-always-delete authenticates a shipped native schema",
                 assertion: "assert result == :ok",
                 assertion_line: 75,
                 required_failures: [
                   %{
                     test_name:
                       "plain: legacy-reference-always-delete authenticates a shipped native schema",
                     assertion: "assert result == :ok",
                     assertion_line: 75
                   },
                   %{
                     test_name:
                       "2: legacy-reference-always-delete authenticates a shipped native schema",
                     assertion: "assert result == :ok",
                     assertion_line: 75
                   }
                 ]
               },
               "legacy-reference-primary-key" => %{
                 path: "priv/templates/migrations/maintenance/reference_legacy.sql",
                 original:
                   "EXECUTE format('ALTER TABLE %s ADD PRIMARY KEY (%s)',relation_oid::regclass,",
                 mutated:
                   "EXECUTE format('ALTER TABLE %s ADD UNIQUE (%s)',relation_oid::regclass,",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_legacy_reference_primary_key_mutation",
                 test_name:
                   "plain: legacy-reference-primary-key authenticates a shipped native schema",
                 assertion: "assert result == :ok",
                 assertion_line: 75,
                 required_failures: [
                   %{
                     test_name:
                       "plain: legacy-reference-primary-key authenticates a shipped native schema",
                     assertion: "assert result == :ok",
                     assertion_line: 75
                   },
                   %{
                     test_name:
                       "2: legacy-reference-primary-key authenticates a shipped native schema",
                     assertion: "assert result == :ok",
                     assertion_line: 75
                   }
                 ]
               },
               "legacy-reference-claim-shape" => %{
                 path: "priv/templates/migrations/external_state/claims.sql",
                 original:
                   "CHECK (\n  (state = 'processing' AND response_partition IS NULL AND response_codec IS NULL AND response_digest IS NULL)\n  OR\n  (state = 'complete' AND response_partition IS NOT NULL AND response_codec IS NOT NULL\n    AND response_digest IS NOT NULL\n    AND octet_length(response_codec) >= 1 AND octet_length(response_codec) <= 128\n    AND octet_length(response_digest) = 32)\n)",
                 mutated: "CHECK (true)",
                 test: "test/ash_onetime/external_state/reference_sites_test.exs",
                 tag: "enforcement_legacy_reference_claim_shape_mutation",
                 test_name:
                   "plain: legacy-reference-claim-shape authenticates a shipped native schema",
                 assertion: "assert result == :ok",
                 assertion_line: 75,
                 required_failures: [
                   %{
                     test_name:
                       "plain: legacy-reference-claim-shape authenticates a shipped native schema",
                     assertion: "assert result == :ok",
                     assertion_line: 75
                   },
                   %{
                     test_name:
                       "2: legacy-reference-claim-shape authenticates a shipped native schema",
                     assertion: "assert result == :ok",
                     assertion_line: 75
                   }
                 ]
               },
               "install-owner-set-role" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'maintenance_owner_set_role: migrating role must be able to SET ROLE to %',owner_name;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/install_guards_test.exs",
                 tag: "enforcement_install_owner_set_role_mutation",
                 test_name: "plain: install-owner-set-role identifies its native install refusal",
                 assertion: "assert actual",
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-owner-set-role identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   },
                   %{
                     test_name: "2: install-owner-set-role identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   }
                 ],
                 assertion_line: 139
               },
               "install-owner-schema-create" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'maintenance_owner_schema_create: owner % needs CREATE on schema %',owner_name,install_schema;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/install_guards_test.exs",
                 tag: "enforcement_install_owner_schema_create_mutation",
                 test_name:
                   "plain: install-owner-schema-create identifies its native install refusal",
                 assertion: "assert actual",
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-owner-schema-create identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   },
                   %{
                     test_name:
                       "2: install-owner-schema-create identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   }
                 ],
                 assertion_line: 139
               },
               "install-function-ownership" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'maintenance_function_ownership: migrating role must own every replaced function';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/install_guards_test.exs",
                 tag: "enforcement_install_function_ownership_mutation",
                 test_name:
                   "plain: install-function-ownership identifies its native install refusal",
                 assertion: "assert actual",
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-function-ownership identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   },
                   %{
                     test_name:
                       "2: install-function-ownership identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   }
                 ],
                 assertion_line: 139
               },
               "install-maintenance-role-exists" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'maintenance_role_missing: declared maintenance role does not exist';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/install_guards_test.exs",
                 tag: "enforcement_install_maintenance_role_exists_mutation",
                 test_name:
                   "plain: install-maintenance-role-exists identifies its native install refusal",
                 assertion: "assert actual",
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-maintenance-role-exists identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   },
                   %{
                     test_name:
                       "2: install-maintenance-role-exists identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   }
                 ],
                 assertion_line: 139
               },
               "install-reserved-policy-refusal" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "RAISE EXCEPTION 'maintenance_blinded: reserved policy ash_onetime_maintenance already exists on %',target.relation_name;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/install_guards_test.exs",
                 tag: "enforcement_install_reserved_policy_refusal_mutation",
                 test_name:
                   "plain: install-reserved-policy-refusal identifies its native install refusal",
                 assertion: "assert actual",
                 required_failures: [
                   %{
                     test_name:
                       "plain: install-reserved-policy-refusal identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   },
                   %{
                     test_name:
                       "2: install-reserved-policy-refusal identifies its native install refusal",
                     assertion: "assert actual",
                     assertion_line: 139
                   }
                 ],
                 assertion_line: 139
               },
               "trust-partition-bound-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original:
                   "RAISE EXCEPTION 'untrusted_dependency: partition bound %',relation_row.relname;",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/catalog_guards_test.exs",
                 tag: "enforcement_trust_partition_bound_refusal_mutation",
                 test_name:
                   "plain: trust-partition-bound-refusal reports its native catalog boundary",
                 assertion: "assert {:error,",
                 assertion_line: 106,
                 required_failures: [
                   %{
                     test_name:
                       "plain: trust-partition-bound-refusal reports its native catalog boundary",
                     assertion: "assert {:error,",
                     assertion_line: 106
                   },
                   %{
                     test_name:
                       "2: trust-partition-bound-refusal reports its native catalog boundary",
                     assertion: "assert {:error,",
                     assertion_line: 106
                   }
                 ]
               },
               "trust-missing-root-refusal" => %{
                 path: "priv/templates/migrations/maintenance/trust.sql",
                 original: "RAISE EXCEPTION 'untrusted_dependency: missing package root';",
                 mutated: "NULL;",
                 test: [
                   "test/ash_onetime/external_state/catalog_guards_test.exs",
                   "test/ash_onetime/external_state/review_acl_test.exs"
                 ],
                 tag: "enforcement_trust_missing_root_refusal_mutation",
                 test_name:
                   "plain: trust-missing-root-refusal reports its native catalog boundary",
                 assertion: "assert actual",
                 assertion_line: 124,
                 required_failures: [
                   %{
                     test_name:
                       "plain: trust-missing-root-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   },
                   %{
                     test_name:
                       "2: trust-missing-root-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   },
                   %{
                     test_name: "plain: trust refuses a missing rollback journal",
                     assertion: "assert {:error,",
                     assertion_line: 69
                   },
                   %{
                     test_name: "2: trust refuses a missing rollback journal",
                     assertion: "assert {:error,",
                     assertion_line: 69
                   }
                 ]
               },
               "capture-date-encoding-refusal" => %{
                 path: "priv/templates/migrations/maintenance/capture.sql",
                 original: "RAISE EXCEPTION 'untrusted_dependency: unsupported date encoding';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/catalog_guards_test.exs",
                 tag: "enforcement_capture_date_encoding_refusal_mutation",
                 test_name:
                   "plain: capture-date-encoding-refusal reports its native catalog boundary",
                 assertion: "assert actual",
                 assertion_line: 124,
                 required_failures: [
                   %{
                     test_name:
                       "plain: capture-date-encoding-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   },
                   %{
                     test_name:
                       "2: capture-date-encoding-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   }
                 ]
               },
               "lock-root-budget-refusal" => %{
                 path: "priv/templates/migrations/maintenance/lock.sql",
                 original:
                   "IF remaining<=0 THEN RAISE EXCEPTION 'maintenance lock budget exhausted' USING ERRCODE='55P03'; END IF; -- root lock budget",
                 mutated: "NULL; -- root lock budget",
                 test: "test/ash_onetime/external_state/catalog_guards_test.exs",
                 tag: "enforcement_lock_root_budget_refusal_mutation",
                 test_name: "plain: lock-root-budget-refusal reports its native catalog boundary",
                 assertion: "assert actual",
                 assertion_line: 124,
                 required_failures: [
                   %{
                     test_name:
                       "plain: lock-root-budget-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   },
                   %{
                     test_name: "2: lock-root-budget-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   }
                 ]
               },
               "lock-parent-owner-refusal" => %{
                 path: "priv/templates/migrations/maintenance/lock.sql",
                 original:
                   "RAISE EXCEPTION 'untrusted_dependency: payload parent owner changed';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/catalog_guards_test.exs",
                 tag: "enforcement_lock_parent_owner_refusal_mutation",
                 test_name:
                   "plain: lock-parent-owner-refusal reports its native catalog boundary",
                 assertion: "assert actual",
                 assertion_line: 124,
                 required_failures: [
                   %{
                     test_name:
                       "plain: lock-parent-owner-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   },
                   %{
                     test_name:
                       "2: lock-parent-owner-refusal reports its native catalog boundary",
                     assertion: "assert actual",
                     assertion_line: 124
                   }
                 ]
               },
               "reference-date-encoding-refusal" => %{
                 path: "priv/templates/migrations/maintenance/reference.sql",
                 original: "RAISE EXCEPTION 'untrusted_dependency: unsupported date encoding';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/reference_dates_test.exs",
                 tag: "enforcement_reference_date_encoding_refusal_mutation",
                 test_name:
                   "plain: reference-date-encoding-refusal refuses a reference changed by owner DDL",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: reference-date-encoding-refusal refuses a reference changed by owner DDL",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: reference-date-encoding-refusal refuses a reference changed by owner DDL",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "legacy-reference-date-encoding-refusal" => %{
                 path: "priv/templates/migrations/maintenance/reference_legacy.sql",
                 original: "RAISE EXCEPTION 'untrusted_dependency: unsupported date encoding';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/reference_dates_test.exs",
                 tag: "enforcement_legacy_reference_date_encoding_refusal_mutation",
                 test_name:
                   "plain: legacy-reference-date-encoding-refusal refuses a reference changed by owner DDL",
                 assertion: "assert actual",
                 assertion_line: 105,
                 required_failures: [
                   %{
                     test_name:
                       "plain: legacy-reference-date-encoding-refusal refuses a reference changed by owner DDL",
                     assertion: "assert actual",
                     assertion_line: 105
                   },
                   %{
                     test_name:
                       "2: legacy-reference-date-encoding-refusal refuses a reference changed by owner DDL",
                     assertion: "assert actual",
                     assertion_line: 105
                   }
                 ]
               },
               "rollback-policy-permissive" => %{
                 path: "priv/templates/migrations/maintenance.exs",
                 original: "'definition',format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s',",
                 mutated:
                   "'definition',format('CREATE POLICY %I ON %s AS RESTRICTIVE /* %s */ FOR %s TO %s%s%s',",
                 test: "test/ash_onetime/external_state/rollback_policies_test.exs",
                 tag: "enforcement_rollback_policy_permissive_mutation",
                 test_name:
                   "plain: rollback-policy-permissive restores policies after mixed-owner function recreation",
                 assertion: "assert after_rollback",
                 assertion_line: 72,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback-policy-permissive restores policies after mixed-owner function recreation",
                     assertion: "assert after_rollback",
                     assertion_line: 72
                   },
                   %{
                     test_name:
                       "2: rollback-policy-permissive restores policies after mixed-owner function recreation",
                     assertion: "assert after_rollback",
                     assertion_line: 72
                   }
                 ]
               },
               "rollback-policy-check" => %{
                 path: "priv/templates/migrations/maintenance.exs",
                 original:
                   "CASE WHEN p.polwithcheck IS NULL THEN '' ELSE format(' WITH CHECK (%s)',pg_get_expr(p.polwithcheck,p.polrelid)) END)",
                 mutated:
                   "CASE WHEN p.polwithcheck IS NULL THEN '' ELSE ' WITH CHECK (false)' END)",
                 test: "test/ash_onetime/external_state/rollback_policies_test.exs",
                 tag: "enforcement_rollback_policy_check_mutation",
                 test_name:
                   "plain: rollback-policy-check restores policies after mixed-owner function recreation",
                 assertion: "assert after_rollback",
                 assertion_line: 72,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback-policy-check restores policies after mixed-owner function recreation",
                     assertion: "assert after_rollback",
                     assertion_line: 72
                   },
                   %{
                     test_name:
                       "2: rollback-policy-check restores policies after mixed-owner function recreation",
                     assertion: "assert after_rollback",
                     assertion_line: 72
                   }
                 ]
               },
               "admission-classify-processing-invalid" => %{
                 path: "lib/ash_onetime/admission.ex",
                 original:
                   "# processing malformed classification\n      _other ->\n        {:error, Error.new(:store_invariant, \"store result violated an invariant\")}",
                 mutated:
                   "# processing malformed classification\n      _other ->\n        {:error, Error.new(:request_in_progress, \"store result violated an invariant\")}",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_processing_invalid_mutation",
                 test_name:
                   "plain: admission-classify-processing-invalid resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-processing-invalid resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-processing-invalid resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "admission-classify-nonce-invalid" => %{
                 path: "lib/ash_onetime/admission.ex",
                 original:
                   "# nonce malformed classification\n      _other ->\n        emit_conflict(state, :malformed)\n        {:error, Error.new(:store_invariant, \"store result violated an invariant\")}",
                 mutated:
                   "# nonce malformed classification\n      _other ->\n        emit_conflict(state, :malformed)\n        {:error, Error.new(:request_in_progress, \"store result violated an invariant\")}",
                 test: "test/ash_onetime/external_state/admission_classification_test.exs",
                 tag: "enforcement_admission_classify_nonce_invalid_mutation",
                 test_name:
                   "plain: admission-classify-nonce-invalid resolves a native store result",
                 assertion: "assert actual",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: admission-classify-nonce-invalid resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: admission-classify-nonce-invalid resolves a native store result",
                     assertion: "assert actual",
                     assertion_line: 162
                   }
                 ]
               },
               "classify-locked-stale-attempt" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "      true ->\n        Result.failure(:request_in_progress, :sent, :open)",
                 mutated: "      true ->\n        Result.failure(:store_invariant, :sent, :open)",
                 test: "test/ash_onetime/external_state/locked_stale_test.exs",
                 tag: "enforcement_classify_locked_stale_attempt_mutation",
                 test_name: "plain: a stale locked attempt stays in progress",
                 assertion: "assert %Result",
                 assertion_line: 19,
                 required_failures: [
                   %{
                     test_name: "plain: a stale locked attempt stays in progress",
                     assertion: "assert %Result",
                     assertion_line: 19
                   },
                   %{
                     test_name: "2: a stale locked attempt stays in progress",
                     assertion: "assert %Result",
                     assertion_line: 19
                   }
                 ]
               },
               "raised-before-checkout" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   ":not_started -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)",
                 mutated: ":not_started -> Result.failure(:disconnected, :unknown, :unknown)",
                 test: [
                   "test/ash_onetime/external_state/query_transport_test.exs",
                   "test/ash_onetime/external_state/validation_order_test.exs"
                 ],
                 tag: "enforcement_raised_before_checkout_mutation",
                 test_name: "plain: a stopped native pool proves checkout never started",
                 assertion: "assert %Result",
                 assertion_line: 18,
                 required_failures: [
                   %{
                     test_name: "plain: a stopped native pool proves checkout never started",
                     assertion: "assert %Result",
                     assertion_line: 18
                   },
                   %{
                     test_name: "2: a stopped native pool proves checkout never started",
                     assertion: "assert %Result",
                     assertion_line: 18
                   }
                 ]
               },
               "raised-after-dispatch" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original: ":sent -> Result.failure(:dispatched_unknown, :unknown, :unknown)",
                 mutated:
                   ":sent -> Result.failure(:checkout_unavailable, :not_started, :not_applicable)",
                 test: "test/ash_onetime/external_state/query_transport_test.exs",
                 tag: "enforcement_raised_after_dispatch_mutation",
                 test_name: "plain: undecodable native state remains dispatched unknown",
                 assertion: "assert %Result",
                 assertion_line: 66,
                 required_failures: [
                   %{
                     test_name: "plain: undecodable native state remains dispatched unknown",
                     assertion: "assert %Result",
                     assertion_line: 66
                   },
                   %{
                     test_name: "2: undecodable native state remains dispatched unknown",
                     assertion: "assert %Result",
                     assertion_line: 66
                   }
                 ]
               },
               "query-connection-error" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(%DBConnection.ConnectionError{}) do\n    Result.failure(:disconnected, :unknown, :unknown)",
                 mutated:
                   "defp classify_query_error(%DBConnection.ConnectionError{}) do\n    Result.failure(:dispatched_unknown, :unknown, :unknown)",
                 test: "test/ash_onetime/external_state/query_transport_test.exs",
                 tag: "enforcement_query_connection_error_mutation",
                 test_name: "plain: a terminated native client stays disconnected after dispatch",
                 assertion: "assert_receive {:lost_client_result,",
                 assertion_line: 115,
                 required_failures: [
                   %{
                     test_name:
                       "plain: a terminated native client stays disconnected after dispatch",
                     assertion: "assert_receive {:lost_client_result,",
                     assertion_line: 115
                   },
                   %{
                     test_name: "2: a terminated native client stays disconnected after dispatch",
                     assertion: "assert_receive {:lost_client_result,",
                     assertion_line: 115
                   }
                 ]
               },
               "catalog-edge-numeric-class" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original: "edge_class := substring(edge_fragment FROM '[$]1=([0-9]+)::oid');",
                 mutated: "edge_class := NULL;",
                 test: "test/ash_onetime/external_state/catalog_edge_install_test.exs",
                 tag: "enforcement_catalog_edge_numeric_class_mutation",
                 test_name:
                   "plain: catalog-edge-numeric-class installs native typed catalog traversal",
                 assertion: "assert result == :ok",
                 assertion_line: 29,
                 required_failures: [
                   %{
                     test_name:
                       "plain: catalog-edge-numeric-class installs native typed catalog traversal",
                     assertion: "assert result == :ok",
                     assertion_line: 29
                   },
                   %{
                     test_name:
                       "2: catalog-edge-numeric-class installs native typed catalog traversal",
                     assertion: "assert result == :ok",
                     assertion_line: 29
                   }
                 ]
               },
               "catalog-edge-named-class" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "edge_class := (substring(edge_fragment FROM '[$]1=''([^'']+)''::regclass')::regclass::oid)::text;",
                 mutated: "edge_class := NULL;",
                 test: "test/ash_onetime/external_state/catalog_edge_install_test.exs",
                 tag: "enforcement_catalog_edge_named_class_mutation",
                 test_name:
                   "plain: catalog-edge-named-class installs native typed catalog traversal",
                 assertion: "assert result == :ok",
                 assertion_line: 29,
                 required_failures: [
                   %{
                     test_name:
                       "plain: catalog-edge-named-class installs native typed catalog traversal",
                     assertion: "assert result == :ok",
                     assertion_line: 29
                   },
                   %{
                     test_name:
                       "2: catalog-edge-named-class installs native typed catalog traversal",
                     assertion: "assert result == :ok",
                     assertion_line: 29
                   }
                 ]
               },
               "query-other-error" => %{
                 path: "lib/ash_onetime/store/postgres.ex",
                 original:
                   "defp classify_query_error(_error) do\n    Result.failure(:dispatched_unknown, :unknown, :unknown)",
                 mutated:
                   "defp classify_query_error(_error) do\n    Result.failure(:store_invariant, :sent, :rolled_back)",
                 test: "test/ash_onetime/external_state/query_transport_test.exs",
                 tag: "enforcement_query_other_error_mutation",
                 test_name: "plain: a real COPY connection refusal remains dispatched unknown",
                 assertion: "assert_receive",
                 assertion_line: 150,
                 required_failures: [
                   %{
                     test_name:
                       "plain: a real COPY connection refusal remains dispatched unknown",
                     assertion: "assert_receive",
                     assertion_line: 150
                   },
                   %{
                     test_name: "2: a real COPY connection refusal remains dispatched unknown",
                     assertion: "assert_receive",
                     assertion_line: 150
                   }
                 ]
               }
             })

  @mutations Map.merge(@mutations, %{
               "responses-expired-telemetry" => %{
                 path: "lib/ash_onetime/telemetry.ex",
                 original:
                   "cleanup: [\n      :responses_expired,\n      :claims_deleted,\n      :partitions_dropped,\n      :partitions_created,\n      :partitions_kept\n    ]",
                 mutated:
                   "cleanup: [\n      :claims_deleted,\n      :partitions_dropped,\n      :partitions_created,\n      :partitions_kept\n    ]",
                 test: "test/ash_onetime/telemetry_test.exs",
                 tag: "review_telemetry_classes",
                 test_name: "cleanup emits the responses_expired class to attached handlers",
                 assertion: "assert :ok = result",
                 assertion_line: 124
               },
               "outcome-unrecorded-telemetry" => %{
                 path: "lib/ash_onetime/telemetry.ex",
                 original: "      :outcome_unrecorded,\n",
                 mutated: "",
                 test: "test/ash_onetime/telemetry_test.exs",
                 tag: "review_telemetry_classes",
                 test_name:
                   "external_recovery emits the outcome_unrecorded class to attached handlers",
                 assertion: "assert :ok = result",
                 assertion_line: 124
               }
             })

  # Review repair mutation rows.
  @mutations Map.merge(@mutations, %{
               "external-journal-capture" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "SELECT p.oid::regprocedure::text,pg_get_functiondef(p.oid),p.proowner,p.proconfig,p.prosecdef,p.proacl",
                 mutated:
                   "SELECT p.oid::regprocedure::text,pg_get_functiondef(p.oid),p.proowner,NULL,p.prosecdef,NULL",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name: "plain: rollback restores every prior routine definition and grant",
                 assertion: "assert :ok = migrate(c, 13, source, :down)",
                 assertion_line: 51,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback restores every prior routine definition and grant",
                     assertion: "assert :ok = migrate(c, 13, source, :down)",
                     assertion_line: 51
                   },
                   %{
                     test_name: "2: rollback restores every prior routine definition and grant",
                     assertion: "assert :ok = migrate(c, 13, source, :down)",
                     assertion_line: 51
                   }
                 ]
               },
               "external-journal-restore-definition" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "EXECUTE item->>'definition';",
                 mutated: "NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name: "plain: rollback restores every prior routine definition and grant",
                 assertion: "assert :ok = migrate(c, 13, source, :down)",
                 assertion_line: 51,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback restores every prior routine definition and grant",
                     assertion: "assert :ok = migrate(c, 13, source, :down)",
                     assertion_line: 51
                   },
                   %{
                     test_name: "2: rollback restores every prior routine definition and grant",
                     assertion: "assert :ok = migrate(c, 13, source, :down)",
                     assertion_line: 51
                   }
                 ]
               },
               "external-journal-clear-grants" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "        FOR grantee IN SELECT DISTINCT a.grantee FROM pg_proc p,\n          LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=routine_oid LOOP\n          EXECUTE format('REVOKE ALL PRIVILEGES ON FUNCTION %s FROM %s CASCADE',routine_oid::regprocedure,\n            CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);",
                 mutated:
                   "        FOR grantee IN SELECT DISTINCT a.grantee FROM pg_proc p,\n          LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=routine_oid AND false LOOP\n          EXECUTE format('REVOKE ALL PRIVILEGES ON FUNCTION %s FROM %s CASCADE',routine_oid::regprocedure,\n            CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name: "plain: rollback restores every prior routine definition and grant",
                 assertion: "assert routines(c) == before",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback restores every prior routine definition and grant",
                     assertion: "assert routines(c) == before",
                     assertion_line: 52
                   },
                   %{
                     test_name: "2: rollback restores every prior routine definition and grant",
                     assertion: "assert routines(c) == before",
                     assertion_line: 52
                   }
                 ]
               },
               "external-journal-restore-grants" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "SELECT g AS value FROM jsonb_array_elements(item->'acl') g",
                 mutated:
                   "SELECT g AS value FROM jsonb_array_elements(item->'acl') g WHERE false",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name: "plain: rollback restores every prior routine definition and grant",
                 assertion: "assert routines(c) == before",
                 assertion_line: 52,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback restores every prior routine definition and grant",
                     assertion: "assert routines(c) == before",
                     assertion_line: 52
                   },
                   %{
                     test_name: "2: rollback restores every prior routine definition and grant",
                     assertion: "assert routines(c) == before",
                     assertion_line: 52
                   }
                 ]
               },
               "external-journal-primary-key" => %{
                 path: "priv/templates/migrations/external_state/restore.sql",
                 original: ", PRIMARY KEY (routine_identity)",
                 mutated: "",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name: "plain: the journal primary key refuses a duplicate routine snapshot",
                 assertion: "assert {:error",
                 assertion_line: 232,
                 required_failures: [
                   %{
                     test_name:
                       "plain: the journal primary key refuses a duplicate routine snapshot",
                     assertion: "assert {:error",
                     assertion_line: 232
                   },
                   %{
                     test_name: "2: the journal primary key refuses a duplicate routine snapshot",
                     assertion: "assert {:error",
                     assertion_line: 232
                   }
                 ]
               },
               "external-journal-owner-only" => %{
                 path: "priv/templates/migrations/external_state/restore.sql",
                 original:
                   "      FOR grantee IN SELECT DISTINCT a.grantee FROM pg_class c,\n        LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a\n        WHERE c.oid=format('%I.ash_onetime_external_state_restore',install_schema)::regclass\n          AND a.grantee<>c.relowner LOOP\n        EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE %I.ash_onetime_external_state_restore FROM %s CASCADE',install_schema,\n          CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);",
                 mutated:
                   "      FOR grantee IN SELECT DISTINCT a.grantee FROM pg_class c,\n        LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a\n        WHERE c.oid=format('%I.ash_onetime_external_state_restore',install_schema)::regclass\n          AND false LOOP\n        EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE %I.ash_onetime_external_state_restore FROM %s CASCADE',install_schema,\n          CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: the rollback journal captures all six routines with owner-only grants",
                 assertion: "assert scalar",
                 assertion_line: 115,
                 required_failures: [
                   %{
                     test_name:
                       "plain: the rollback journal captures all six routines with owner-only grants",
                     assertion: "assert scalar",
                     assertion_line: 115
                   },
                   %{
                     test_name:
                       "2: the rollback journal captures all six routines with owner-only grants",
                     assertion: "assert scalar",
                     assertion_line: 115
                   }
                 ]
               },
               "external-journal-capture-complete" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      IF (SELECT count(*) FROM \#{q(\"ash_onetime_external_state_restore\")})<>6 THEN",
                 mutated: "      IF false THEN",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name: "plain: upgrade refuses to capture fewer than six prior routines",
                 assertion: "assert {:error",
                 assertion_line: 186,
                 required_failures: [
                   %{
                     test_name: "plain: upgrade refuses to capture fewer than six prior routines",
                     assertion: "assert {:error",
                     assertion_line: 186
                   },
                   %{
                     test_name: "2: upgrade refuses to capture fewer than six prior routines",
                     assertion: "assert {:error",
                     assertion_line: 186
                   }
                 ]
               },
               "external-journal-missing" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      IF to_regclass(format('%I.ash_onetime_external_state_restore',install_schema)) IS NULL THEN",
                 mutated: "      IF false THEN",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: rollback refuses a missing journal without changing external state",
                 assertion: "assert {:error",
                 assertion_line: 135,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback refuses a missing journal without changing external state",
                     assertion: "assert {:error",
                     assertion_line: 135
                   },
                   %{
                     test_name:
                       "2: rollback refuses a missing journal without changing external state",
                     assertion: "assert {:error",
                     assertion_line: 135
                   }
                 ]
               },
               "external-journal-coverage" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      IF (SELECT count(*) FROM \#{q(\"ash_onetime_external_state_restore\")})<>6 OR EXISTS (\n        SELECT 1 FROM jsonb_array_elements(\#{maintenance_literal(Jason.encode!(Enum.filter(@external_functions, &(&1.name in @previous_names))))}::jsonb) r\n        WHERE NOT EXISTS (SELECT 1 FROM \#{q(\"ash_onetime_external_state_restore\")} j\n          WHERE to_regprocedure(j.routine_identity)=to_regprocedure(format('%I.%I(%s)',install_schema,r->>'name',r->>'types')))) THEN",
                 mutated: "      IF false THEN",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: rollback refuses an incomplete journal without changing external state",
                 assertion: "assert {:error",
                 assertion_line: 162,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback refuses an incomplete journal without changing external state",
                     assertion: "assert {:error",
                     assertion_line: 162
                   },
                   %{
                     test_name:
                       "2: rollback refuses an incomplete journal without changing external state",
                     assertion: "assert {:error",
                     assertion_line: 162
                   }
                 ]
               },
               "external-journal-restore-attributes" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "        IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid=routine_oid\n          AND p.proowner=(item->>'owner_oid')::oid\n          AND p.prosecdef=(item->>'security_definer')::boolean\n          AND to_jsonb(p.proconfig) IS NOT DISTINCT FROM nullif(item->'configuration','null'::jsonb)) THEN",
                 mutated: "      IF false THEN",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: rollback refuses journal attributes inconsistent with its saved definition",
                 assertion: "assert {:error",
                 assertion_line: 213,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback refuses journal attributes inconsistent with its saved definition",
                     assertion: "assert {:error",
                     assertion_line: 213
                   },
                   %{
                     test_name:
                       "2: rollback refuses journal attributes inconsistent with its saved definition",
                     assertion: "assert {:error",
                     assertion_line: 213
                   }
                 ]
               },
               "external-up-restore-role" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      -- rule:external-up-restore-role\n      PERFORM set_config('role',migrating_role,true);",
                 mutated: "      -- rule:external-up-restore-role\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: external upgrade restores the migrating role before its journal insert",
                 assertion: "assert :ok =",
                 assertion_line: 245,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external upgrade restores the migrating role before its journal insert",
                     assertion: "assert :ok =",
                     assertion_line: 245
                   },
                   %{
                     test_name:
                       "2: external upgrade restores the migrating role before its journal insert",
                     assertion: "assert :ok =",
                     assertion_line: 245
                   }
                 ]
               },
               "external-routines-restore-role" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      -- rule:external-routines-restore-role\n      PERFORM set_config('role',migrating_role,true);",
                 mutated: "      -- rule:external-routines-restore-role\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: external upgrade restores the migrating role before its journal insert",
                 assertion: "assert :ok =",
                 assertion_line: 245,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external upgrade restores the migrating role before its journal insert",
                     assertion: "assert :ok =",
                     assertion_line: 245
                   },
                   %{
                     test_name:
                       "2: external upgrade restores the migrating role before its journal insert",
                     assertion: "assert :ok =",
                     assertion_line: 245
                   }
                 ]
               },
               "external-outcomes-restore-role" => %{
                 path: "priv/templates/migrations/external_state/outcomes.sql",
                 original:
                   "      -- rule:external-outcomes-restore-role\n      PERFORM set_config('role',migrating_role,true);",
                 mutated: "      -- rule:external-outcomes-restore-role\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: external upgrade restores the migrating role before its journal insert",
                 assertion: "assert :ok =",
                 assertion_line: 245,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external upgrade restores the migrating role before its journal insert",
                     assertion: "assert :ok =",
                     assertion_line: 245
                   },
                   %{
                     test_name:
                       "2: external upgrade restores the migrating role before its journal insert",
                     assertion: "assert :ok =",
                     assertion_line: 245
                   }
                 ]
               },
               "external-down-restore-role" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      -- rule:external-down-restore-role\n      PERFORM set_config('role',migrating_role,true);",
                 mutated: "      -- rule:external-down-restore-role\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: external rollback restores the migrating role before its journal delete",
                 assertion: "assert :ok = migrate(%{c | owner_repo: migrator}",
                 assertion_line: 266,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external rollback restores the migrating role before its journal delete",
                     assertion: "assert :ok = migrate(%{c | owner_repo: migrator}",
                     assertion_line: 266
                   },
                   %{
                     test_name:
                       "2: external rollback restores the migrating role before its journal delete",
                     assertion: "assert :ok = migrate(%{c | owner_repo: migrator}",
                     assertion_line: 266
                   }
                 ]
               },
               "external-down-owner" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      -- rule:external-down-owner\n      PERFORM set_config('role',owner_name,true);",
                 mutated: "      -- rule:external-down-owner\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: external rollback restores the migrating role before its journal delete",
                 assertion: "assert :ok = migrate(%{c | owner_repo: migrator}",
                 assertion_line: 266,
                 required_failures: [
                   %{
                     test_name:
                       "plain: external rollback restores the migrating role before its journal delete",
                     assertion: "assert :ok = migrate(%{c | owner_repo: migrator}",
                     assertion_line: 266
                   },
                   %{
                     test_name:
                       "2: external rollback restores the migrating role before its journal delete",
                     assertion: "assert :ok = migrate(%{c | owner_repo: migrator}",
                     assertion_line: 266
                   }
                 ]
               },
               "external-down-force-read" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      -- rule:external-down-force-read\n      IF force_claims THEN ALTER TABLE \#{q(@claims)} NO FORCE ROW LEVEL SECURITY; END IF;",
                 mutated: "      -- rule:external-down-force-read\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: rollback succeeds under FORCE and restores both row security flags",
                 assertion: "assert :ok = migrate(c, 13, source, :down)",
                 assertion_line: 293,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback succeeds under FORCE and restores both row security flags",
                     assertion: "assert :ok = migrate(c, 13, source, :down)",
                     assertion_line: 293
                   },
                   %{
                     test_name:
                       "2: rollback succeeds under FORCE and restores both row security flags",
                     assertion: "assert :ok = migrate(c, 13, source, :down)",
                     assertion_line: 293
                   }
                 ]
               },
               "external-down-force-restore" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original:
                   "      -- rule:external-down-force-restore\n      IF force_claims THEN ALTER TABLE \#{q(@claims)} FORCE ROW LEVEL SECURITY; END IF;",
                 mutated: "      -- rule:external-down-force-restore\n      NULL;",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: rollback succeeds under FORCE and restores both row security flags",
                 assertion: "assert [[true, true]]",
                 assertion_line: 295,
                 required_failures: [
                   %{
                     test_name:
                       "plain: rollback succeeds under FORCE and restores both row security flags",
                     assertion: "assert [[true, true]]",
                     assertion_line: 295
                   },
                   %{
                     test_name:
                       "2: rollback succeeds under FORCE and restores both row security flags",
                     assertion: "assert [[true, true]]",
                     assertion_line: 295
                   }
                 ]
               },
               "external-public-execute" => %{
                 path: "priv/templates/migrations/external_state.exs",
                 original: "IF routine->>'grant_class'='public_invoker' THEN",
                 mutated:
                   "IF routine->>'grant_class' IN ('step','public_invoker') OR routine->>'name'='ash_onetime_cleanup_eligible' THEN",
                 test: "test/ash_onetime/external_state/review_upgrade_test.exs",
                 tag: "external_state_review_upgrade",
                 test_name:
                   "plain: without maintenance an unprivileged role cannot execute ash_onetime_expire_responses",
                 assertion: "assert {:error",
                 assertion_line: 334,
                 required_failures: [
                   %{
                     test_name:
                       "plain: without maintenance an unprivileged role cannot execute ash_onetime_expire_responses",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "plain: without maintenance an unprivileged role cannot execute ash_onetime_cleanup_idempotency",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "plain: without maintenance an unprivileged role cannot execute ash_onetime_cleanup_nonce",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "plain: without maintenance an unprivileged role cannot execute ash_onetime_reap_idempotency",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "plain: without maintenance an unprivileged role cannot execute ash_onetime_cleanup_eligible",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "2: without maintenance an unprivileged role cannot execute ash_onetime_expire_responses",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "2: without maintenance an unprivileged role cannot execute ash_onetime_cleanup_idempotency",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "2: without maintenance an unprivileged role cannot execute ash_onetime_cleanup_nonce",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "2: without maintenance an unprivileged role cannot execute ash_onetime_reap_idempotency",
                     assertion: "assert {:error",
                     assertion_line: 334
                   },
                   %{
                     test_name:
                       "2: without maintenance an unprivileged role cannot execute ash_onetime_cleanup_eligible",
                     assertion: "assert {:error",
                     assertion_line: 334
                   }
                 ]
               },
               "acl-child-table-owner-only" => %{
                 path: "priv/templates/migrations/maintenance/acl.sql",
                 original:
                   "    -- rule:acl-child-table-owner-only\n    WHERE c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner",
                 mutated:
                   "    -- rule:acl-child-table-owner-only\n    WHERE false AND c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner",
                 test: "test/ash_onetime/external_state/review_acl_test.exs",
                 tag: "external_state_review_acl",
                 test_name:
                   "plain: ACL refuses every table and column grant on ash_onetime_response_payloads children",
                 assertion: "assert [[false]]",
                 assertion_line: 121,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ACL refuses every table and column grant on ash_onetime_response_payloads children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "2: ACL refuses every table and column grant on ash_onetime_idempotency_claims children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "2: ACL refuses every table and column grant on ash_onetime_nonce_claims children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "2: ACL refuses every table and column grant on ash_onetime_response_payloads children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "plain: ACL audits table and column grants on the rollback journal",
                     assertion: "assert [[false]]",
                     assertion_line: 50
                   },
                   %{
                     test_name: "2: ACL audits table and column grants on the rollback journal",
                     assertion: "assert [[false]]",
                     assertion_line: 50
                   }
                 ]
               },
               "acl-child-column-owner-only" => %{
                 path: "priv/templates/migrations/maintenance/acl.sql",
                 original:
                   "    -- rule:acl-child-column-owner-only\n    WHERE c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner",
                 mutated:
                   "    -- rule:acl-child-column-owner-only\n    WHERE false AND c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner",
                 test: "test/ash_onetime/external_state/review_acl_test.exs",
                 tag: "external_state_review_acl",
                 test_name:
                   "plain: ACL refuses every table and column grant on ash_onetime_response_payloads children",
                 assertion: "assert [[false]]",
                 assertion_line: 121,
                 required_failures: [
                   %{
                     test_name:
                       "plain: ACL refuses every table and column grant on ash_onetime_response_payloads children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "2: ACL refuses every table and column grant on ash_onetime_idempotency_claims children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "2: ACL refuses every table and column grant on ash_onetime_nonce_claims children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "2: ACL refuses every table and column grant on ash_onetime_response_payloads children",
                     assertion: "assert [[false]]",
                     assertion_line: 121
                   },
                   %{
                     test_name:
                       "plain: ACL audits table and column grants on the rollback journal",
                     assertion: "assert [[false]]",
                     assertion_line: 50
                   },
                   %{
                     test_name: "2: ACL audits table and column grants on the rollback journal",
                     assertion: "assert [[false]]",
                     assertion_line: 50
                   }
                 ]
               },
               "journal-reset-owner-only" => %{
                 path: "priv/templates/migrations/maintenance/reset_acl.sql",
                 original:
                   "owner_only := owner_only OR (SELECT relname='ash_onetime_external_state_restore' FROM pg_class WHERE oid=relation_oid);",
                 mutated: "owner_only := owner_only;",
                 test: "test/ash_onetime/external_state/review_acl_test.exs",
                 tag: "external_state_review_journal_acl",
                 test_name:
                   "plain: reset ACL keeps the rollback journal owner-only in every mode",
                 assertion: "refute scalar",
                 assertion_line: 34,
                 required_failures: [
                   %{
                     test_name:
                       "plain: reset ACL keeps the rollback journal owner-only in every mode",
                     assertion: "refute scalar",
                     assertion_line: 34
                   },
                   %{
                     test_name:
                       "2: reset ACL keeps the rollback journal owner-only in every mode",
                     assertion: "refute scalar",
                     assertion_line: 34
                   }
                 ]
               },
               "private-routine-schema" => %{
                 path: "priv/templates/migrations/maintenance_helpers.exs",
                 original:
                   "EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM PUBLIC',routine_schema);",
                 mutated: "EXECUTE format('GRANT USAGE ON SCHEMA %I TO PUBLIC',routine_schema);",
                 test: "test/ash_onetime/external_state/review_acl_test.exs",
                 tag: "external_state_review_schema_usage",
                 test_name: "plain: the private routine schema grants no PUBLIC usage",
                 assertion: "refute scalar",
                 assertion_line: 145,
                 required_failures: [
                   %{
                     test_name: "plain: the private routine schema grants no PUBLIC usage",
                     assertion: "refute scalar",
                     assertion_line: 145
                   },
                   %{
                     test_name: "2: the private routine schema grants no PUBLIC usage",
                     assertion: "refute scalar",
                     assertion_line: 145
                   }
                 ]
               },
               "doctor-rollback-journal" => %{
                 path: "lib/mix/tasks/ash_onetime.doctor.ex",
                 original:
                   "AND to_regclass(format('%I.ash_onetime_external_state_restore',$1::text)) IS NOT NULL",
                 mutated: "AND true",
                 test: "test/ash_onetime/external_state/doctor_test.exs",
                 tag: "external_state_review_journal_doctor",
                 test_name: "plain: doctor refuses a missing rollback journal",
                 assertion: "assert_raise Mix.Error",
                 assertion_line: 19,
                 required_failures: [
                   %{
                     test_name: "plain: doctor refuses a missing rollback journal",
                     assertion: "assert_raise Mix.Error",
                     assertion_line: 19
                   },
                   %{
                     test_name: "2: doctor refuses a missing rollback journal",
                     assertion: "assert_raise Mix.Error",
                     assertion_line: 19
                   }
                 ]
               }
             })

  @groups %{
    "all" => Map.keys(@mutations),
    "defects-batch" => [
      "M-doctor-fact-schema",
      "M-complete-restore",
      "M-replica-admit-nonce",
      "M-replica-lookup-claims-up",
      "M-replica-lookup-claims-down",
      "M-firing-down-claims",
      "M-firing-down-nonce",
      "M-fact-schema",
      "M-fact-upgrade-schema",
      "M-dst-complete",
      "M-dst-release",
      "M-complete",
      "M-firing-claims",
      "M-firing-nonce",
      "M-firing-fact",
      "M-replica-admit",
      "M-replica-lookup",
      "M-firing-upgrade",
      "M-contain",
      "M-holder",
      "M-internal",
      "M-extmember",
      "M-oid",
      "M-evt-trust",
      "M-evt-doctor",
      "M-doctor-runtime"
    ],
    "shipped-maintenance" => [
      "maintenance-upgrade-validation",
      "maintenance-upgrade-constraint-count",
      "maintenance-upgrade-constraint-coverage",
      "maintenance-logical-primary",
      "maintenance-upgrade-check-names",
      "maintenance-upgrade-reference",
      "maintenance-normalize-attnum",
      "maintenance-restore-fixpoint"
    ],
    "replay-relationships" => [
      "replay-callback-error-rollback",
      "replay-relationship-clearing",
      "replay-relationship-rollback",
      "generic-replay-relationship-backstop"
    ],
    "response-allowlist" => ["response-field-guard"],
    "return-type" => ["return-contract"],
    "dsl-verifiers" => [
      "dsl-idempotency",
      "dsl-nonce",
      "dsl-nonce-key",
      "dsl-lifecycle",
      "dsl-duplicate",
      "dsl-references",
      "dsl-builtin-options",
      "dsl-validations",
      "dsl-attribute-tenant-scope"
    ],
    "operation-hash" => [
      "operation-hash-select",
      "operation-hash-completion",
      "operation-hash-cleanup"
    ],
    "reap" => [
      "reap-removes-abandoned",
      "reap-retention-guard",
      "reap-floor-guard",
      "reap-skips-locked-recovery"
    ],
    "safety-properties" =>
      [
        "replay-execution",
        "corrupt-replay-execution",
        "completion",
        "crud-result-tuple",
        "crud-completion",
        "atomic-error-form",
        "bulk-fallback",
        "state-request-sanitization",
        "state-claim-sanitization",
        "completion-codec",
        "completion-payload",
        "completion-digest",
        "completion-partition",
        "completion-partition-clock",
        "completion-state",
        "completion-outer",
        "completion-transaction",
        "untracked-siblings",
        "admitted-identity",
        "fingerprint-identity",
        "operation-identity",
        "scope-identity",
        "key-identity",
        "marker-propagation",
        "generic-preparation",
        "notifier-guard",
        "around-capability",
        "nonce-around-capability",
        "pure-producer-capability",
        "marker-consumption-capability",
        "wrapper-protection",
        "dynamic-repo",
        "prefix-routing",
        "authorization-order",
        "ledger-tamper",
        "reserved-input",
        "composite-clock",
        "composite-expiry",
        "composite-cleanup",
        "composite-verifier-order",
        "composite-sibling-validation"
      ] ++ Enum.map(@forbidden_telemetry, fn {field, _value} -> "telemetry-#{field}" end)
  }

  @groups Map.put(@groups, "mutation-checker-attribution", [
            "mutation-checker-failure-attribution"
          ])

  @groups Map.put(@groups, "external-state-claims", [
            "claim-trigger-identity-id",
            "claim-trigger-identity-logical_partition",
            "claim-trigger-identity-operation_hash",
            "claim-trigger-identity-scope_hash",
            "claim-trigger-identity-key_hash",
            "claim-trigger-identity-fingerprint",
            "claim-trigger-identity-effect_local",
            "claim-trigger-identity-admitted_at",
            "claim-trigger-identity-inserted_at",
            "claim-trigger-insert-shape",
            "claim-trigger-insert-time",
            "claim-trigger-attempt-step",
            "claim-trigger-attempt-processing",
            "claim-trigger-expire-step",
            "claim-trigger-expire-held",
            "claim-trigger-expire-early",
            "claim-trigger-expire-payload",
            "claim-trigger-response-fixed",
            "claim-trigger-completion-count",
            "claim-trigger-completion-locator",
            "claim-trigger-retain-clamp",
            "claim-trigger-response-retain-clamp",
            "claim-trigger-derive-insert",
            "claim-trigger-derive-update",
            "claim-trigger-inline-active",
            "claim-trigger-inline-eligible",
            "claims-check-effect",
            "claims-check-processing",
            "claims-check-expired",
            "claims-check-deadline-order"
          ])

  @groups Map.put(@groups, "external-state-maintenance", [
            "expire-lock-mode",
            "reap-guard-kind",
            "reap-kind-predicate",
            "expire-skips-held",
            "expire-selects-eligible",
            "expire-payload-cardinality",
            "cleanup-expired-payload-count"
          ])

  @groups Map.put(@groups, "external-state-outcomes", [
            "outcomes-primary-key",
            "outcomes-check-outcome",
            "outcomes-check-attempt",
            "outcome-guard-update",
            "outcome-guard-parent-lookup",
            "outcome-guard-row-security",
            "outcome-guard-definer",
            "outcome-bound-attempt",
            "outcome-bound-late",
            "fk-present",
            "fk-cascade"
          ])

  @groups Map.put(@groups, "external-state-protocol", [
            "verifier-response-retention",
            "cache-ttl-response-deadline",
            "reserve-external-kind",
            "grant-attempt-increment",
            "classify-attempt",
            "classify-complete-replay",
            "completion-attempt-bind",
            "outcome-insert-attempt",
            "outcome-worker-timeout"
          ])

  @groups Map.put(@groups, "external-state-audits", [
            "claim-trigger-replica-branch",
            "trust-outcome-holders",
            "trust-outcome-column-holders",
            "visibility-helper-acl-audit",
            "policy-claim-visibility",
            "outcome-acl-column",
            "outcome-acl-runtime",
            "acl-outcome-exemption",
            "install-outcome-append-only",
            "visibility-helper-public",
            "outcome-rls-follows-claims",
            "outcome-bound-invoker",
            "always-claim-trigger",
            "always-outcome-guard",
            "always-outcome-bound",
            "claim-trigger-replica-trusted",
            "outcome-bound-replica-trusted"
          ])

  @groups Map.put(@groups, "external-state-additional", [
            "lock-l3",
            "lock-l4",
            "visibility-helper-settings",
            "rollback-refusal-install"
          ])

  @groups Map.put(@groups, "external-state-guards", [
            "delete-guard-inline-eligibility",
            "nonce-guard-inline-eligibility"
          ])

  @groups Map.put(@groups, "external-state-upgrade", [
            "upgrade-legacy-keys",
            "upgrade-shape-authentication",
            "rollback-refusal-external-state",
            "rollback-refusal-expired",
            "rollback-refusal-maintenance",
            "generator-order",
            "reference-graph-complete",
            "shape-ri-normalization",
            "operation-hold-do-block"
          ])

  @groups Map.put(@groups, "external-state-last-rows", [
            "rollback-lock-install",
            "rollback-lock-external-state",
            "rollback-lock-maintenance",
            "roll-relocation",
            "cleanup-complete-only",
            "expired-after-fingerprint",
            "load-after-claim-lock"
          ])

  @groups Map.put(@groups, "inventory-self-tests", [
            "inventory-unmarked-enforcer",
            "inventory-unmarked-reraise",
            "inventory-missing-row",
            "inventory-catalog-equality"
          ])

  @groups Map.put(@groups, "enforcement-inventory", [
            "nonce-select-lock",
            "idempotency-claims-check-logical-partition",
            "idempotency-claims-check-operation-hash",
            "idempotency-claims-check-scope-hash",
            "idempotency-claims-check-key-hash",
            "idempotency-claims-check-fingerprint",
            "idempotency-claims-check-state",
            "idempotency-claims-check-hold",
            "idempotency-claims-check-retention",
            "idempotency-claims-check-inserted-at",
            "nonce-claims-check-logical-partition",
            "nonce-claims-check-operation-hash",
            "nonce-claims-check-scope-hash",
            "nonce-claims-check-key-hash",
            "nonce-claims-check-verifier-id",
            "nonce-claims-check-expiry",
            "nonce-claims-check-issued-retention",
            "nonce-claims-check-admitted-retention",
            "nonce-claims-check-inserted-at",
            "response-payloads-check-logical-partition",
            "response-payloads-check-size",
            "idempotency-claims-primary-key",
            "nonce-claims-primary-key",
            "payload-primary-key",
            "facts-check-tenant",
            "facts-check-type",
            "facts-check-tags",
            "facts-primary-key",
            "facts-append-only-refusal",
            "maintenance-runs-primary-key",
            "maintenance-runs-check-step",
            "maintenance-routine-support",
            "maintenance-routine-executable-trees",
            "claim-trigger-inline-active",
            "claim-trigger-inline-eligible",
            "cleanup-idempotency-arguments",
            "cleanup-nonce-arguments",
            "expire-arguments",
            "reap-batch-arguments",
            "reap-horizon-arguments",
            "prune-arguments",
            "roll-default-force-1",
            "roll-default-force-2",
            "roll-reraise",
            "inventory-unmarked-reraise",
            "routine-step-definer",
            "routine-helper-invoker",
            "routine-inside-search-path",
            "outcome-bound-search-path",
            "outcome-guard-search-path",
            "visibility-helper-search-path",
            "install-routine-security",
            "complete-candidate-lock",
            "nonce-candidate-lock",
            "processing-candidate-lock",
            "maintenance-root-column-authority",
            "current-delete-unarmed",
            "current-delete-processing-payload",
            "current-delete-count-after",
            "hold-delete-unarmed",
            "hold-delete-boundary",
            "hold-delete-processing-payload",
            "hold-delete-retention",
            "hold-delete-count-before",
            "hold-delete-count-after",
            "hold-delete-held",
            "previous-delete-unarmed",
            "previous-delete-boundary",
            "previous-delete-processing-payload",
            "previous-delete-retention",
            "previous-delete-count-before",
            "previous-delete-count-after",
            "hold-cleanup-arguments",
            "hold-cleanup-row-lock",
            "previous-cleanup-arguments",
            "previous-cleanup-row-lock",
            "external-reference-invoker",
            "external-reference-search-path",
            "external-routine-security",
            "install-shapes-invoker",
            "install-policy-invoker",
            "install-trust-invoker",
            "query-classify-privilege",
            "query-classify-lock",
            "query-classify-completion-unknown",
            "query-classify-connection",
            "query-classify-shutdown",
            "query-classify-idle",
            "query-classify-transient",
            "query-classify-postgres-other",
            "effect-classify-local",
            "effect-classify-resolved",
            "effect-classify-finalized",
            "effect-classify-unknown",
            "effect-classify-held",
            "effect-classify-absent-proven",
            "effect-classify-unresolved",
            "classifier-outcome",
            "classifier-invalid",
            "classifier-rescue",
            "classifier-catch",
            "classifier-fallback",
            "logical-column-check",
            "logical-downgrade-refusal",
            "logical-collision-required",
            "operation-hold-check",
            "operation-hold-rollback-held",
            "operation-hold-rollback-unresolved",
            "external-hold-required",
            "maintenance-hold-required",
            "maintenance-external-required",
            "upgrade-enable-claim-delete",
            "loaded-processing",
            "loaded-expired",
            "loaded-complete",
            "loaded-corrupt",
            "loaded-nonce",
            "loaded-invalid",
            "collision-nonce",
            "collision-loaded-success",
            "collision-loaded-failure",
            "install-upgrade-policy-policy",
            "install-upgrade-policy-check",
            "install-maintenance-policy",
            "install-maintenance-check",
            "install-claim-visibility-policy",
            "install-claim-visibility-check",
            "external-maintenance-policy",
            "external-maintenance-check",
            "external-claim-visibility-policy",
            "external-claim-visibility-check",
            "copy-policy-check",
            "trust-relation-shape-refusal",
            "trust-policy-refusal",
            "trust-authority-refusal",
            "trust-helper-public-refusal",
            "trust-package-acl-refusal",
            "trust-partition-date-refusal",
            "maintenance-classify-arguments",
            "maintenance-classify-timeout",
            "maintenance-classify-lock",
            "maintenance-classify-privilege",
            "maintenance-classify-isolation",
            "maintenance-classify-blinded",
            "maintenance-classify-dependency",
            "maintenance-classify-blocked",
            "maintenance-classify-raised-other",
            "maintenance-classify-fallback",
            "maintenance-classify-result",
            "admission-classify-expired-mismatch",
            "admission-classify-complete-mismatch",
            "admission-classify-processing-mismatch",
            "admission-classify-admitted",
            "admission-classify-processing-local",
            "admission-classify-processing-committed",
            "admission-classify-processing-finalize",
            "admission-classify-processing-locked",
            "admission-classify-complete",
            "admission-classify-expired-invalid",
            "admission-classify-nonce",
            "reference-always-delete",
            "reference-always-claim-update",
            "reference-always-outcome-guard",
            "reference-always-outcome-bound",
            "legacy-reference-always-delete",
            "legacy-reference-primary-key",
            "legacy-reference-claim-shape",
            "install-owner-set-role",
            "install-owner-schema-create",
            "install-function-ownership",
            "install-maintenance-role-exists",
            "install-reserved-policy-refusal",
            "trust-partition-bound-refusal",
            "trust-missing-root-refusal",
            "capture-date-encoding-refusal",
            "lock-root-budget-refusal",
            "lock-parent-owner-refusal",
            "reference-date-encoding-refusal",
            "legacy-reference-date-encoding-refusal",
            "rollback-policy-permissive",
            "rollback-policy-check",
            "admission-classify-processing-invalid",
            "admission-classify-nonce-invalid",
            "classify-locked-stale-attempt",
            "raised-before-checkout",
            "raised-after-dispatch",
            "query-connection-error",
            "catalog-edge-numeric-class",
            "catalog-edge-named-class",
            "query-other-error"
          ])

  @registered @mutations |> Map.keys() |> MapSet.new()

  def manifest, do: @mutations

  def main(["--manifest"]) do
    IO.puts(
      Jason.encode!(
        Map.new(@mutations, fn {name, row} ->
          {name,
           Map.take(row, [
             :path,
             :original,
             :mutated,
             :test,
             :tag,
             :test_name,
             :assertion,
             :assertion_line
           ])}
        end)
      )
    )
  end

  def main(["--self-test"]) do
    case validate(["unregistered-mutation"]) do
      {:error, ["unregistered-mutation"]} ->
        IO.puts("mutation checker self-test: unknown mutations fail closed")

      result ->
        IO.puts(:stderr, "mutation checker self-test failed: #{inspect(result)}")
        System.halt(1)
    end

    grouped = @groups |> Map.values() |> List.flatten() |> MapSet.new()
    orphaned = @registered |> MapSet.difference(grouped) |> MapSet.to_list() |> Enum.sort()

    case orphaned do
      [] ->
        IO.puts("mutation checker self-test: every registered mutation is in a runnable group")

      names ->
        IO.puts(
          :stderr,
          "mutation checker self-test failed: orphaned mutations: #{Enum.join(names, ", ")}"
        )

        System.halt(1)
    end

    # rule:source-site-audit-proof
    audit_registered_sites!()
    audit_shards!()

    execution_guard_closed? =
      try do
        assert_exunit_execution!("self-test", "SIGTERM received - shutting down")
        false
      rescue
        RuntimeError -> true
      end

    if execution_guard_closed? do
      IO.puts("mutation checker self-test: restoration requires an executed ExUnit result")
    else
      IO.puts(:stderr, "mutation checker self-test failed: restoration receipt guard opened")
      System.halt(1)
    end
  end

  def main(["--" | names]), do: main(names)

  # CI splits the battery into jobs: shard I of N runs every Nth of the requested mutations,
  # sorted by name, starting at the Ith. Every shard count partitions the request exactly.
  def main(["--shard", spec | names]) do
    {index, total} = parse_shard!(spec)
    names |> expand() |> shard(index, total) |> run()
  rescue
    exception ->
      IO.puts(:stderr, Exception.message(exception))
      System.halt(1)
  end

  def main(names), do: names |> expand() |> run()

  defp expand(names), do: names |> Enum.flat_map(&Map.get(@groups, &1, [&1])) |> Enum.uniq()

  defp shard(names, index, total) do
    names
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.filter(fn {_name, position} -> rem(position, total) == index - 1 end)
    |> Enum.map(fn {name, _position} -> name end)
  end

  defp parse_shard!(spec) do
    with [index, total] <- String.split(spec, "/"),
         {index, ""} <- Integer.parse(index),
         {total, ""} <- Integer.parse(total),
         true <- total >= 1 and index >= 1 and index <= total do
      {index, total}
    else
      _ -> raise "--shard takes I/N with 1 <= I <= N, not #{inspect(spec)}"
    end
  end

  defp audit_shards! do
    all = @groups |> Map.fetch!("all") |> Enum.sort()

    for total <- 1..8 do
      shards = Enum.map(1..total, &shard(all, &1, total))

      unless shards |> List.flatten() |> Enum.sort() == all do
        raise "mutation checker self-test failed: #{total} shards do not partition the battery"
      end
    end

    for spec <- ["0/4", "5/4", "1/0", "1", "a/4", "1/4/2"] do
      refused? =
        try do
          parse_shard!(spec)
          false
        rescue
          RuntimeError -> true
        end

      unless refused? do
        raise "mutation checker self-test failed: shard #{inspect(spec)} was accepted"
      end
    end

    IO.puts("mutation checker self-test: every shard count partitions the battery exactly")
  end

  defp run(names) do
    case validate(names) do
      :ok ->
        case Enum.flat_map(names, &run_collecting_failure/1) do
          [] ->
            IO.puts("mutation checks passed: #{Enum.join(names, ", ")}")

          failures ->
            IO.puts(:stderr, "mutation checks failed (#{length(failures)}):")

            Enum.each(failures, fn {name, message} ->
              IO.puts(:stderr, "  #{name}: #{message}")
            end)

            System.halt(1)
        end

      {:error, unknown} ->
        IO.puts(:stderr, "unknown mutation checks: #{Enum.join(unknown, ", ")}")
        System.halt(2)
    end
  rescue
    exception ->
      IO.puts(:stderr, Exception.message(exception))
      System.halt(1)
  end

  # One failing mutation must not hide the next: every mutation runs and every failure is
  # reported. Continuing is safe only on exact source bytes, so a mutation that leaves its
  # file changed stops the battery at once.
  defp run_collecting_failure(name) do
    mutation = Map.fetch!(@mutations, name)
    original_source = File.read!(mutation.path)

    try do
      run_mutation!(name, mutation)
      []
    rescue
      exception ->
        unless File.read!(mutation.path) == original_source do
          reraise exception, __STACKTRACE__
        end

        message = Exception.message(exception)
        IO.puts(:stderr, "mutation #{name}: FAILED: #{message}")
        [{name, message}]
    end
  end

  defp run_mutation!(name, mutation) do
    original_source = File.read!(mutation.path)
    assert_single_site!(original_source, mutation.original, mutation.path)

    mutated_source =
      String.replace(original_source, mutation.original, mutation.mutated, global: false)

    IO.puts("mutation #{name}: source edit #{mutation.original} -> #{mutation.mutated}")

    required_failures =
      Map.get(mutation, :required_failures, [{mutation.test_name, mutation.assertion}])
      |> Enum.map(fn
        {test_name, assertion} -> %{test_name: test_name, assertion: assertion}
        failure when is_map(failure) -> failure
      end)

    for %{test_name: test_name, assertion: assertion} <- required_failures do
      IO.puts("mutation #{name}: expected failing test: #{test_name}")
      IO.puts("mutation #{name}: expected failing assertion: #{assertion}")
    end

    {red_output, red_status} =
      try do
        File.write!(mutation.path, mutated_source)
        probe_fixture!(name, mutation)
        run_test(mutation)
      after
        File.write!(mutation.path, original_source)
      end

    IO.puts("mutation #{name}: mutant command output follows")
    IO.puts(red_output)

    if red_status == 0 do
      unless Regex.match?(~r/Result: [1-9][0-9]* passed/, red_output) do
        raise "mutation #{name} ran no owned test: it was skipped or excluded on this substrate"
      end

      raise "mutation #{name} survived its owned test"
    end

    failure_records = AshOnetime.MutationFailures.records(red_output)

    unless Enum.all?(required_failures, fn failure ->
             AshOnetime.MutationFailures.matches?(
               failure_records,
               Map.merge(mutation, failure),
               failure.test_name,
               failure.assertion
             )
           end) do
      raise "mutation #{name} failed without every required named assertion"
    end

    assert_summary!(name, :mutant, red_output, Map.get(mutation, :red_summary))

    unless File.read!(mutation.path) == original_source do
      raise "mutation #{name} did not restore exact source bytes"
    end

    {restored_output, restored_status} = run_test(mutation)
    IO.puts("mutation #{name}: restored command output follows")
    IO.puts(restored_output)

    if restored_status != 0 do
      raise "mutation #{name} did not return green after restoration"
    end

    assert_exunit_execution!(name, restored_output)

    assert_summary!(name, :restored, restored_output, Map.get(mutation, :green_summary))

    IO.puts("mutation #{name}: RED confirmed; exact source bytes restored; tagged test GREEN")
  end

  defp assert_single_site!(source, needle, path) do
    case :binary.matches(source, needle) do
      [_single] -> :ok
      matches -> raise "mutation site count for #{path} was #{length(matches)}, expected 1"
    end
  end

  defp audit_registered_sites! do
    Enum.each(@mutations, fn {name, mutation} ->
      source = File.read!(mutation.path)

      case :binary.matches(source, mutation.original) do
        [_single] ->
          :ok

        matches ->
          raise "mutation #{name} site count for #{mutation.path} was #{length(matches)}, expected 1"
      end
    end)

    IO.puts("mutation checker self-test: every registered mutation has exactly one source site")
  end

  defp assert_summary!(_name, _phase, _output, nil), do: :ok

  defp assert_summary!(name, phase, output, expected) do
    unless String.contains?(output, expected) do
      raise "mutation #{name} #{phase} output omitted required summary #{inspect(expected)}"
    end
  end

  defp assert_exunit_execution!(name, output) do
    # rule:restoration-execution-proof
    unless executed_exunit_result?(output) do
      raise "mutation #{name} restoration did not execute a complete green ExUnit result"
    end
  end

  defp executed_exunit_result?(output) do
    String.contains?(output, "Running ExUnit") and
      String.contains?(output, "Finished in") and
      Regex.match?(~r/Result: [1-9][0-9]* passed/, output) and
      not String.contains?(output, "Failed:") and
      not String.contains?(output, "SIGTERM received")
  end

  defp probe_fixture!(_name, %{probe: nil}), do: :ok

  defp probe_fixture!(name, %{probe: {fixture, expected}}) do
    fixture = Path.expand(Path.join("test/compile_fixtures", fixture))
    env = mutation_environment()

    {compile_output, compile_status} =
      System.cmd("mix", ["compile", "--force"], env: env, stderr_to_stdout: true)

    if compile_status != 0 do
      raise "mutation #{name} failed to compile:\n#{compile_output}"
    end

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "scripts/probe_compile_fixture.exs", fixture, expected],
        env: env,
        stderr_to_stdout: true
      )

    IO.puts("mutation #{name}: direct fixture probe output follows")
    IO.puts(output)

    unless status == 0 and output =~ "ASH_ONETIME_FIXTURE_RESULT=compiled" and
             output =~ "ASH_ONETIME_FIXTURE_LOADED=true" do
      raise "mutation #{name} did not make its owned fixture compile and load"
    end
  end

  defp probe_fixture!(_name, _mutation), do: :ok

  defp run_test(mutation) do
    env = mutation_environment()

    System.cmd(
      "mix",
      ["test", "--force"] ++
        List.wrap(mutation.test) ++
        [
          "--only",
          mutation.tag,
          "--seed",
          "0",
          "--formatter",
          "AshOnetime.Test.MutationFormatter",
          "--formatter",
          "ExUnit.CLIFormatter"
        ],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp mutation_environment do
    [
      {"MIX_ENV", "test"},
      # The battery always targets the same dedicated database the parent test
      # run validated (test_helper fails closed on its shape first); refusing
      # to start without it beats silently retargeting a hardcoded URL.
      {"DATABASE_URL", System.fetch_env!("DATABASE_URL")}
    ]
    |> maybe_put_build_path(System.get_env("MIX_BUILD_PATH"))
  end

  defp maybe_put_build_path(environment, nil), do: environment

  defp maybe_put_build_path(environment, build_path),
    do: [{"MIX_BUILD_PATH", build_path} | environment]

  defp validate([]), do: {:error, ["no mutation checks requested"]}

  defp validate(names) do
    unknown = Enum.reject(names, &MapSet.member?(@registered, &1))
    if unknown == [], do: :ok, else: {:error, unknown}
  end
end

AshOnetime.MutationCheck.main(System.argv())
