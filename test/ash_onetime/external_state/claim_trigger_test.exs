defmodule AshOnetime.ExternalState.ClaimTriggerTest do
  use AshOnetime.Test.ExternalStateCase, async: false

  @moduletag :external_state_claim_trigger_mutation

  for {column, value} <- [
        {"id", "gen_random_uuid()"},
        {"logical_partition", "'another-partition'"},
        {"operation_hash", "sha256('other-operation'::bytea)"},
        {"scope_hash", "sha256('other-scope'::bytea)"},
        {"key_hash", "sha256('other-key'::bytea)"},
        {"fingerprint", "sha256('other-request'::bytea)"},
        {"effect_local", "true"},
        {"admitted_at", "admitted_at-interval '1 second'"},
        {"inserted_at", "inserted_at+interval '1 second'"}
      ] do
    @column column
    @value value
    test "identity #{@column} is immutable", c do
      id = insert_claim(c, attempt: 0)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               query(c, "#{@column}=#{@value}", id)
    end
  end

  test "insert shape refuses a completed claim and an ungranted attempt", c do
    for statement <- [
          "state='complete',response_partition=CURRENT_DATE,response_codec='test',response_digest=sha256('response'::bytea)",
          "effect_attempt=2"
        ] do
      sql = insert_statement(c, statement)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
               SQL.query(c.runtime_repo, sql, [])
    end
  end

  test "insert timestamps cannot backdate the retention and abandonment clocks", c do
    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             SQL.query(
               c.runtime_repo,
               insert_statement(
                 c,
                 "admitted_at=transaction_timestamp()-interval '1 day',inserted_at=transaction_timestamp()-interval '1 day'"
               ),
               []
             )
  end

  test "attempts advance exactly one while processing", c do
    id = insert_claim(c)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             query(c, "effect_attempt=effect_attempt+2", id)

    assert {:ok, %{num_rows: 1}} = query(c, "effect_attempt=effect_attempt+1", id)
  end

  test "a completed claim cannot grant another attempt", c do
    id = insert_claim(c) |> then(&complete_claim(c, &1))

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             query(c, "effect_attempt=effect_attempt+1", id)
  end

  test "a local claim cannot grant an external attempt", c do
    id = insert_claim(c, local: true)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             query(c, "effect_attempt=1", id)
  end

  test "processing claims cannot carry response expiry", c do
    id = insert_claim(c)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             query(c, "response_expired_at=transaction_timestamp()", id)
  end

  test "response deadlines cannot exceed claim deadlines", c do
    id = insert_claim(c)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             query(c, "response_retain_until=retain_until+interval '1 second'", id)
  end

  test "deadline clamps preserve the original claim and response deadlines", c do
    id = insert_claim(c)
    before = deadlines(c, id)

    assert {:ok, _} =
             query(
               c,
               "retain_until=retain_until-interval '1 hour',response_retain_until=response_retain_until-interval '1 hour'",
               id
             )

    assert deadlines(c, id) == before
  end

  test "response-only deadline clamp preserves the original response deadline", c do
    id = insert_claim(c)
    before = deadlines(c, id)

    assert {:ok, _} =
             query(c, "response_retain_until=response_retain_until-interval '1 hour'", id)

    assert deadlines(c, id) == before
  end

  test "insert derives a missing response deadline", c do
    assert id = insert_claim(c, response_deadline: "NULL")
    assert [[retain, retain]] = deadlines(c, id)
  end

  test "legacy deadline extension moves the response deadline by the same duration", c do
    id = insert_claim(c)
    [[retain, response]] = deadlines(c, id)
    assert {:ok, _} = query(c, "retain_until=retain_until+interval '1 hour'", id)
    assert [[DateTime.add(retain, 3600), DateTime.add(response, 3600)]] == deadlines(c, id)
  end

  test "completion requires exactly one payload at the response locator", c do
    id = insert_claim(c)

    completion =
      "state='complete',response_partition=CURRENT_DATE,response_codec='test',response_digest=sha256('response'::bytea)"

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = query(c, completion, id)

    SQL.query!(
      c.runtime_repo,
      "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (partition_date,claim_id,encoded_response) VALUES (CURRENT_DATE+1,$1::uuid,'response'::bytea)",
      [Ecto.UUID.dump!(id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = query(c, completion, id)

    SQL.query!(
      c.runtime_repo,
      "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (partition_date,claim_id,encoded_response) VALUES (CURRENT_DATE,$1::uuid,'response'::bytea)",
      [Ecto.UUID.dump!(id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = query(c, completion, id)
  end

  test "a born-expired completion is refused even inside maintenance", c do
    id = insert_claim(c, response_deadline: "transaction_timestamp()-interval '1 second'")

    SQL.query!(
      c.runtime_repo,
      "INSERT INTO #{rel(c, "ash_onetime_response_payloads")} (partition_date,claim_id,encoded_response) VALUES (CURRENT_DATE,$1::uuid,'response'::bytea)",
      [Ecto.UUID.dump!(id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             query(c, "state='complete',response_expired_at=transaction_timestamp()", id)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             expiry_update(
               c,
               c.owner_repo,
               id,
               "state='complete',response_expired_at=transaction_timestamp()"
             )
  end

  for {name, options, remove_payload} <- [
        {"runtime", [], true},
        {"held", [hold: "retained-operation"], true},
        {"early", [early: true], true},
        {"payload", [], false}
      ] do
    @name name
    @options options
    @remove_payload remove_payload
    test "expiry refuses #{@name} with SQLSTATE 23514", c do
      response =
        if @options[:early],
          do: "transaction_timestamp()+interval '1 hour'",
          else: "transaction_timestamp()-interval '1 second'"

      id = insert_claim(c, response_deadline: response) |> then(&complete_claim(c, &1, @options))

      if @remove_payload,
        do:
          SQL.query!(
            c.runtime_repo,
            "DELETE FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1::uuid",
            [Ecto.UUID.dump!(id)]
          )

      repo = if @name == "runtime", do: c.runtime_repo, else: c.owner_repo
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = expiry_update(c, repo, id)
    end
  end

  test "expiry must clear all response columns", c do
    id =
      insert_claim(c, response_deadline: "transaction_timestamp()-interval '1 second'")
      |> then(&complete_claim(c, &1))

    SQL.query!(
      c.runtime_repo,
      "DELETE FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1::uuid",
      [Ecto.UUID.dump!(id)]
    )

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} =
             expiry_update(c, c.owner_repo, id, "response_expired_at=transaction_timestamp()")
  end

  for {name, expired, assignment} <- [
        {"a changed response column", false, "response_codec='another'"},
        {"unexpired complete to processing", false,
         "state='processing',response_partition=NULL,response_codec=NULL,response_digest=NULL"},
        {"expired response reset with valid columns", true,
         "response_expired_at=NULL,response_partition=CURRENT_DATE,response_codec='test',response_digest=sha256('response'::bytea)"},
        {"expired complete to processing", true, "state='processing',response_expired_at=NULL"}
      ] do
    @name name
    @expired expired
    @assignment assignment
    test "completed response refuses #{@name}", c do
      id =
        insert_claim(c, response_deadline: "transaction_timestamp()-interval '1 second'")
        |> then(&complete_claim(c, &1))

      if @expired do
        SQL.query!(
          c.runtime_repo,
          "DELETE FROM #{rel(c, "ash_onetime_response_payloads")} WHERE claim_id=$1::uuid",
          [Ecto.UUID.dump!(id)]
        )

        assert {:ok, _} = expiry_update(c, c.owner_repo, id)
      end

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = query(c, @assignment, id)
    end
  end

  defp deadlines(c, id),
    do:
      SQL.query!(
        c.runtime_repo,
        "SELECT retain_until,response_retain_until FROM #{rel(c, "ash_onetime_idempotency_claims")} WHERE id=$1::uuid",
        [Ecto.UUID.dump!(id)]
      ).rows

  defp expiry_update(
         c,
         repo,
         id,
         assignment \\ "response_partition=NULL,response_codec=NULL,response_digest=NULL,response_expired_at=transaction_timestamp()"
       ) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      case Repo.transaction(fn ->
             if repo == c.owner_repo,
               do: SQL.query!(repo, "SET LOCAL ash_onetime.maintenance='on'", [])

             case SQL.query(
                    repo,
                    "UPDATE #{rel(c, "ash_onetime_idempotency_claims")} SET #{assignment} WHERE id=$1::uuid",
                    [Ecto.UUID.dump!(id)]
                  ) do
               {:ok, result} -> result
               {:error, error} -> Repo.rollback(error)
             end
           end) do
        result -> result
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp insert_statement(c, assignments) do
    changes =
      assignments
      |> String.split(",")
      |> Map.new(fn item ->
        [key, value] = String.split(item, "=", parts: 2)
        {key, value}
      end)

    values =
      [
        {"id", "gen_random_uuid()"},
        {"logical_partition", "'global'"},
        {"operation_hash", "sha256('operation'::bytea)"},
        {"scope_hash", "sha256('scope'::bytea)"},
        {"key_hash", "sha256(gen_random_uuid()::text::bytea)"},
        {"fingerprint", "sha256('request'::bytea)"},
        {"state", "'processing'"},
        {"effect_local", "false"},
        {"effect_attempt", "1"},
        {"admitted_at", "transaction_timestamp()"},
        {"inserted_at", "transaction_timestamp()"},
        {"retain_until", "transaction_timestamp()+interval '1 hour'"},
        {"response_partition", "NULL"},
        {"response_codec", "NULL"},
        {"response_digest", "NULL"}
      ]
      |> Enum.map(fn {key, value} -> {key, Map.get(changes, key, value)} end)

    "INSERT INTO #{rel(c, "ash_onetime_idempotency_claims")} (#{Enum.map_join(values, ",", &elem(&1, 0))}) VALUES (#{Enum.map_join(values, ",", &elem(&1, 1))})"
  end
end
