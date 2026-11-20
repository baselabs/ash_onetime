for partitioning <- [nil, 2], variant <- [:current, :hold, :previous] do
  defmodule Module.concat(AshOnetime.ExternalState.DeleteGuardsTest, "#{variant}Claims#{partitioning || "Plain"}") do
    use AshOnetime.Test.ExternalStateCase, async: false
    alias AshOnetime.Test.{SchemaFixture, ShippedMigrations}
    alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true
    @variant variant

    for {kind, message} <- [
      {:unarmed, "processing idempotency claims are recovery points and cannot be deleted"},
      {:boundary, "processing idempotency claims are recovery points and cannot be deleted"},
      {:processing_payload, "reaped processing idempotency claim unexpectedly carries a payload"},
      {:retention, "idempotency claim is inside its retention horizon"},
      {:count_before, "completed idempotency claim payload cardinality mismatch"},
      {:count_after, "completed idempotency claim payload cardinality mismatch"},
      {:held, "held idempotency claim cannot be deleted; release its operation hold first"}
    ], not (variant == :previous and kind == :held) do
      @kind kind
      @message message
      @tag [{String.to_atom("enforcement_#{variant}_delete_#{kind}_mutation"), true}]
      test "#{partitioning || "plain"}: #{variant} delete refuses #{kind} at its owning guard", c do
        prepare(c)

        id = Ecto.UUID.generate()
        processing = @kind in [:unarmed, :boundary, :processing_payload]
        retained = @kind == :retention
        retain = if retained, do: "transaction_timestamp()+interval '1 day'", else: "transaction_timestamp()-interval '1 day'"
        response = if processing, do: "NULL,NULL,NULL", else: "CURRENT_DATE,'test',sha256('response'::bytea)"
        current_columns = if @variant == :current, do: ",effect_local,effect_attempt,response_retain_until", else: ""
        current_values = if @variant == :current, do: ",true,0,#{retain}", else: ""
        held_columns = if @kind == :held, do: ",hold_reference", else: ""
        held_values = if @kind == :held, do: ",'retained'", else: ""
        previous = Repo.put_dynamic_repo(c.owner_repo)

        try do
          assert {:ok, _} = Repo.transaction(fn ->
            SQL.query!(c.owner_repo, "SET LOCAL session_replication_role=replica", [])
            SQL.query!(c.owner_repo, "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,inserted_at,response_partition,response_codec,response_digest#{current_columns}#{held_columns}) VALUES ($1::uuid,'global',sha256('operation'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),'#{if processing, do: "processing", else: "complete"}',transaction_timestamp()-interval '2 days',#{retain},transaction_timestamp()-interval '2 days',#{response}#{current_values}#{held_values})", [Ecto.UUID.dump!(id)])
            if @kind not in [:unarmed, :boundary, :count_before] do
              SQL.query!(c.owner_repo, "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) VALUES ('global',CURRENT_DATE,$1::uuid,'response'::bytea)", [Ecto.UUID.dump!(id)])
            end
          end)
        after
          Repo.put_dynamic_repo(previous)
        end

        if @kind in [:count_before, :count_after] do
          body = if @kind == :count_before, do: "BEGIN RAISE EXCEPTION 'payload DELETE reached before cardinality refusal' USING ERRCODE='P0002'; END", else: "BEGIN RETURN NULL; END"
          SQL.query!(c.owner_repo, "CREATE FUNCTION #{rel(c, "payload_delete_policy")}() RETURNS trigger LANGUAGE plpgsql AS #{literal(body)}", [])
          timing = if @kind == :count_before, do: "STATEMENT", else: "ROW"
          SQL.query!(c.owner_repo, "CREATE TRIGGER consumer_delete BEFORE DELETE ON #{rel(c, "ash_onetime_response_payloads")} FOR EACH #{timing} EXECUTE FUNCTION #{rel(c, "payload_delete_policy")}()", [])
        end

        previous = Repo.put_dynamic_repo(c.runtime_repo)

        try do
          Repo.transaction(fn ->
            SQL.query!(c.runtime_repo, "SET LOCAL search_path=#{q(c.schema)},pg_catalog", [])
            if @kind != :unarmed do
              cutoff = if @kind == :boundary, do: "transaction_timestamp()-interval '3 days'", else: "transaction_timestamp()"
              SQL.query!(c.runtime_repo, "SELECT set_config('ash_onetime.reap_before',(#{cutoff})::text,true)", [])
            end

            assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514", message: @message}}} = SQL.query(c.runtime_repo, "DELETE FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid", [Ecto.UUID.dump!(id)])
            Repo.rollback(:guard_checked)
          end)
        after
          Repo.put_dynamic_repo(previous)
        end
      end
    end

    if @variant != :current do
      @tag [{String.to_atom("enforcement_#{variant}_cleanup_arguments_mutation"), true}]
      test "#{partitioning || "plain"}: #{variant} cleanup refuses a zero batch", c do
        prepare(c)
        assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023", message: "invalid cleanup batch size"}}} = SQL.query(c.runtime_repo, "SELECT #{rel(c, "ash_onetime_cleanup_idempotency")}(0)", [])
      end

      @tag [{String.to_atom("enforcement_#{variant}_cleanup_row_lock_mutation"), true}]
      test "#{partitioning || "plain"}: #{variant} cleanup skips a held KEY SHARE", c do
        prepare(c)
        id = Ecto.UUID.generate()
        SQL.query!(c.owner_repo, "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (id,logical_partition,operation_hash,scope_hash,key_hash,fingerprint,state,admitted_at,retain_until,inserted_at,response_partition,response_codec,response_digest) VALUES ($1::uuid,'global',sha256('operation'::bytea),sha256('scope'::bytea),sha256('key'::bytea),sha256('request'::bytea),'complete',transaction_timestamp()-interval '2 days',transaction_timestamp()-interval '1 day',transaction_timestamp()-interval '2 days',CURRENT_DATE,'test',sha256('response'::bytea))", [Ecto.UUID.dump!(id)])
        SQL.query!(c.owner_repo, "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (logical_partition,partition_date,claim_id,encoded_response) VALUES ('global',CURRENT_DATE,$1::uuid,'response'::bytea)", [Ecto.UUID.dump!(id)])
        holder = connection!(c, :owner, 1)
        waiter = connection!(c, :runtime, 1)
        previous = Repo.put_dynamic_repo(holder)

        try do
          Repo.transaction(fn ->
            SQL.query!(holder, "SELECT id FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid FOR KEY SHARE", [Ecto.UUID.dump!(id)])
            SQL.query!(waiter, "SET search_path=#{q(c.schema)},pg_catalog", [])
            SQL.query!(waiter, "SET statement_timeout='3s'", [])
            assert {:ok, %{rows: [[0]]}} = SQL.query(waiter, "SELECT #{rel(c, "ash_onetime_cleanup_idempotency")}(1)", [])
          end)
        after
          Repo.put_dynamic_repo(previous)
        end
      end
    end

    defp prepare(c) do
    if @variant == :current do
      assert :ok = install(c)
    else
      options = if c[:hash_partitions], do: [hash_partitions: c.hash_partitions], else: []
      assert :ok = SchemaFixture.migrate!(c, ShippedMigrations.render("v0.6.0", :render, Repo, options), 10)
      assert :ok = SchemaFixture.migrate!(c, Generator.render_logical_partition_upgrade(Repo, []), 11)
      assert :ok = SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12)
      if @variant == :previous, do: assert(:ok == SchemaFixture.migrate!(c, Generator.render_operation_hold_upgrade(Repo, []), 12, :down))
    end
    end
  end
end
