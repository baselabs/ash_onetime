for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.LogicalReplicationTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.LogicalReplicationCase, async: false
    alias AshOnetime.Store.Postgres
    @moduletag hash_partitions: partitioning

    test "#{partitioning || "plain"}: the dedicated logical server supports publication and subscription",
         c do
      assert scalar(c.pub.admin, "SHOW wal_level") == "logical"

      assert scalar(c.pub.admin, "SELECT current_database()") !=
               scalar(c.sub.admin, "SELECT current_database()")

      subscribe!(c, c.sub.owner)
      assert %{path: path, offset: offset} = log_checkpoint!(c)
      assert is_binary(path) and offset > 0

      assert scalar(
               c.pub.admin,
               "SELECT count(*) FROM pg_replication_slots WHERE slot_name=#{literal(c.slot)}"
             ) == 1
    end

    for attack <- [
          :claim_delete,
          :nonce_delete,
          :claim_insert,
          :outcome_delete,
          :outcome_insert,
          :fact_update,
          :fact_delete
        ] do
      @tag [{:"external_state_logical_#{attack}_mutation", true}]
      @tag logical_attack: attack
      test "#{partitioning || "plain"}: untrusted logical apply refuses #{attack}", c do
        attack = c.logical_attack
        id = seed_completed!(c)

        for installation <- [c.pub, c.sub] do
          replica!(installation, fn ->
            SQL.query!(
              installation.owner_repo,
              "UPDATE #{rel(installation, "ash_onetime_idempotency_claims")} SET state='processing',effect_attempt=1,response_partition=NULL,response_codec=NULL,response_digest=NULL,retain_until=transaction_timestamp()+interval '1 day',response_retain_until=transaction_timestamp()+interval '1 day'",
              []
            )

            SQL.query!(
              installation.owner_repo,
              "INSERT INTO #{rel(installation, "ash_onetime_nonce_claims")} (id,operation_hash,scope_hash,key_hash,verifier_id,issued_at,admitted_at,retain_until,inserted_at) VALUES ($1::uuid,sha256('op'::bytea),sha256('scope'::bytea),sha256('nonce'::bytea),'test',transaction_timestamp(),transaction_timestamp(),transaction_timestamp()+interval '1 day',transaction_timestamp())",
              [Ecto.UUID.dump!(id)]
            )

            SQL.query!(
              installation.owner_repo,
              "INSERT INTO #{rel(installation, "replication_facts")} (seq,tenant,type,tags) VALUES (1,'global','retained',ARRAY['fact'])",
              []
            )
          end)
        end

        operation =
          case attack do
            :claim_delete -> {"ash_onetime_idempotency_claims", "DELETE"}
            :nonce_delete -> {"ash_onetime_nonce_claims", "DELETE"}
            :claim_insert -> {"ash_onetime_idempotency_claims", "INSERT"}
            :outcome_delete -> {"ash_onetime_effect_outcomes", "DELETE"}
            :outcome_insert -> {"ash_onetime_effect_outcomes", "INSERT"}
            :fact_update -> {"replication_facts", "UPDATE"}
            :fact_delete -> {"replication_facts", "DELETE"}
          end

        subscribe!(c, c.apply_role, run_as_owner: true, operation: operation)
        checkpoint = log_checkpoint!(c)

        replica!(c.pub, fn ->
          case attack do
            :claim_delete ->
              SQL.query!(
                c.pub.owner_repo,
                "DELETE FROM #{rel(c.pub, "ash_onetime_idempotency_claims")}",
                []
              )

            :nonce_delete ->
              SQL.query!(
                c.pub.owner_repo,
                "DELETE FROM #{rel(c.pub, "ash_onetime_nonce_claims")}",
                []
              )

            :claim_insert ->
              SQL.query!(
                c.pub.owner_repo,
                "INSERT INTO #{rel(c.pub, "ash_onetime_idempotency_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,response_partition,response_codec,response_digest,inserted_at,hold_reference,effect_local,effect_attempt,response_retain_until,response_expired_at) SELECT gen_random_uuid(),logical_partition,operation_hash,scope_hash,sha256('second-key'::bytea),fingerprint,'complete',admitted_at,retain_until,current_date,'test',sha256('response'::bytea),inserted_at,hold_reference,effect_local,effect_attempt,response_retain_until,response_expired_at FROM #{rel(c.pub, "ash_onetime_idempotency_claims")}",
                []
              )

            :outcome_delete ->
              SQL.query!(c.pub.owner_repo,
                "ALTER TABLE #{rel(c.pub, "ash_onetime_effect_outcomes")} DISABLE TRIGGER ash_onetime_effect_outcome_guard", [])
              try do
                SQL.query!(c.pub.owner_repo,
                  "DELETE FROM #{rel(c.pub, "ash_onetime_effect_outcomes")} WHERE attempt=1", [])
              after
                SQL.query!(c.pub.owner_repo,
                  "ALTER TABLE #{rel(c.pub, "ash_onetime_effect_outcomes")} ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_guard", [])
              end

            :outcome_insert ->
              columns =
                if c.pub.hash_partitions, do: "operation_hash,logical_partition,", else: ""

              values = if c.pub.hash_partitions, do: "sha256('op'::bytea),'global',", else: ""

              SQL.query!(
                c.pub.owner_repo,
                "INSERT INTO #{rel(c.pub, "ash_onetime_effect_outcomes")} (#{columns}claim_id,attempt,outcome,recorded_at) VALUES (#{values}$1::uuid,3,'held',transaction_timestamp())",
                [Ecto.UUID.dump!(id)]
              )

            :fact_update ->
              SQL.query!(
                c.pub.owner_repo,
                "ALTER TABLE #{rel(c.pub, "replication_facts")} DISABLE TRIGGER replication_facts_append_only",
                []
              )

              SQL.query!(
                c.pub.owner_repo,
                "UPDATE #{rel(c.pub, "replication_facts")} SET type='changed'",
                []
              )

              SQL.query!(
                c.pub.owner_repo,
                "ALTER TABLE #{rel(c.pub, "replication_facts")} ENABLE ALWAYS TRIGGER replication_facts_append_only",
                []
              )

            :fact_delete ->
              SQL.query!(
                c.pub.owner_repo,
                "ALTER TABLE #{rel(c.pub, "replication_facts")} DISABLE TRIGGER replication_facts_append_only",
                []
              )

              SQL.query!(c.pub.owner_repo, "DELETE FROM #{rel(c.pub, "replication_facts")}", [])

              SQL.query!(
                c.pub.owner_repo,
                "ALTER TABLE #{rel(c.pub, "replication_facts")} ENABLE ALWAYS TRIGGER replication_facts_append_only",
                []
              )
          end
        end)

        message =
          case attack do
            :claim_delete ->
              "unresolved or unclassified external idempotency claim cannot be deleted"

            :nonce_delete ->
              "nonce claim is inside its retention horizon"

            :claim_insert ->
              "idempotency claim insert must be processing at its initial attempt"

            :outcome_delete ->
              "effect outcome parent still exists"

            :outcome_insert ->
              "effect outcome attempt was not granted"

            _ ->
              "fact table replication_facts is append-only"
          end

        assert_apply_stopped!(c, checkpoint, "23514", message)

        assert scalar(
                 c.sub.admin,
                 "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_idempotency_claims")}"
               ) == 1

        assert scalar(
                 c.sub.admin,
                 "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_nonce_claims")}"
               ) == 1

        assert scalar(
                 c.sub.admin,
                 "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_effect_outcomes")}"
               ) == 2

        assert scalar(c.sub.admin, "SELECT type FROM #{rel(c.sub, "replication_facts")}") ==
                 "retained"
      end
    end

    for subscription <- [false, true] do
      @tag logical_subscription: subscription
      test "#{partitioning || "plain"}: trust refuses untrusted logical capability subscription=#{subscription}",
           c do
        if c.logical_subscription do
          subscribe!(c, c.apply_role,
            run_as_owner: true,
            operation: {"ash_onetime_idempotency_claims", "INSERT"}
          )

          SQL.query!(c.sub.admin, "REVOKE pg_create_subscription FROM #{q(c.apply_role)}", [])
        else
          SQL.query!(c.sub.admin, "GRANT pg_create_subscription TO #{q(c.apply_role)}", [])
          database = scalar(c.sub.admin, "SELECT current_database()")

          SQL.query!(
            c.sub.admin,
            "GRANT CREATE ON DATABASE #{q(database)} TO #{q(c.apply_role)}",
            []
          )

          SQL.query!(
            c.sub.admin,
            "GRANT INSERT ON #{rel(c.sub, "ash_onetime_idempotency_claims")} TO #{q(c.apply_role)}",
            []
          )
        end

        routine = Postgres.routine_schema(c.sub.schema)

        assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
                 SQL.query(
                   c.sub.maintainer_repo,
                   "SELECT #{q(routine)}.ash_onetime_cleanup_nonce(1)",
                   []
                 )

        assert message =~ "untrusted_dependency"
        assert message =~ c.apply_role
      end
    end

    for {force, role, owner_bypass, subscriber_bypass, passes} <- [
          {false, :owner, false, false, true},
          {true, :owner, false, false, false},
          {true, :owner, true, true, true},
          {true, :trusted, false, true, false},
          {true, :trusted, true, false, false},
          {true, :trusted, true, true, true}
        ] do
      @tag logical_matrix: %{
             force: force,
             role: role,
             owner_bypass: owner_bypass,
             subscriber_bypass: subscriber_bypass,
             passes: passes
           }
      test "#{partitioning || "plain"}: trusted mirror force=#{force} role=#{role} owner_bypass=#{owner_bypass} subscriber_bypass=#{subscriber_bypass}",
           c do
        seed_completed!(c)
        matrix = c.logical_matrix
        if matrix.force, do: force!(c.sub)
        subscriber = if matrix.role == :owner, do: c.sub.owner, else: c.trusted_role

        if matrix.owner_bypass,
          do: SQL.query!(c.sub.admin, "ALTER ROLE #{q(c.sub.owner)} BYPASSRLS", [])

        if matrix.subscriber_bypass,
          do: SQL.query!(c.sub.admin, "ALTER ROLE #{q(subscriber)} BYPASSRLS", [])

        subscribe!(c, subscriber, run_as_owner: matrix.role == :trusted)
        checkpoint = log_checkpoint!(c)

        SQL.query!(
          c.pub.owner_repo,
          "DELETE FROM #{rel(c.pub, "ash_onetime_idempotency_claims")}",
          []
        )

        if matrix.passes do
          eventually!(fn ->
            scalar(
              c.sub.admin,
              "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_idempotency_claims")}"
            ) == 0
          end)

          assert scalar(
                   c.sub.admin,
                   "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_response_payloads")}"
                 ) == 0

          assert scalar(
                   c.sub.admin,
                   "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_effect_outcomes")}"
                 ) == 0

          assert scalar(
                   c.sub.admin,
                   "SELECT coalesce(sum(apply_error_count),0)::bigint FROM pg_stat_subscription_stats"
                 ) == 0
        else
          message =
            if matrix.role == :trusted and matrix.subscriber_bypass,
              do: "query would be affected by row-level security policy",
              else: "cannot replicate into relation with row-level security enabled"

          assert_apply_stopped!(c, checkpoint, "42501", message)

          assert scalar(
                   c.sub.admin,
                   "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_idempotency_claims")}"
                 ) == 1

          assert scalar(
                   c.sub.admin,
                   "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_response_payloads")}"
                 ) == 1

          assert scalar(
                   c.sub.admin,
                   "SELECT count(*) FROM #{rel(c.sub, "ash_onetime_effect_outcomes")}"
                 ) == 2
        end
      end
    end
  end
end
