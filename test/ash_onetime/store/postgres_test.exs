defmodule AshOnetime.Store.PostgresTest do
  use AshOnetime.Test.StoreCase, async: false

  @moduletag :store

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "idempotency admission collides on the full logical key", %{target: target} do
    request = idempotency_request("idempotency-collision")

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert {:ok, %Result{status: :processing, claim: collided}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert collided.id == claim.id
    assert collided.operation_hash == request.operation_hash
    assert collided.scope_hash == request.scope_hash
    assert collided.key_hash == request.key_hash
  end

  test "nonce admission returns an authoritative collision without response state", %{
    target: target
  } do
    request = nonce_request("nonce-collision")

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert claim.strategy == :one_time_nonce
    assert claim.response_codec == nil

    assert {:ok, %Result{status: :collision, claim: collided}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert collided.id == claim.id
  end

  @tag composite_clock_mutation: true
  test "composite nonce persists a coherent aggregate across crossed issuance and expiry", %{
    target: target
  } do
    evaluated_at = Clock.now() |> DateTime.truncate(:second)
    earlier_issued_at = DateTime.add(evaluated_at, -10, :second)
    latest_issued_at = DateTime.add(evaluated_at, -5, :second)
    earlier_expires_at = DateTime.add(evaluated_at, -8, :second)

    verified = [
      %AshOnetime.Verified{
        key: "earlier",
        issued_at: earlier_issued_at,
        expires_at: earlier_expires_at,
        verifier_id: "verifier-a"
      },
      %AshOnetime.Verified{
        key: "latest",
        issued_at: latest_issued_at,
        expires_at: nil,
        verifier_id: "verifier-b"
      }
    ]

    {:ok, request} =
      Claim.nonce(
        operation_hash: hash("composite-operation"),
        scope_hash: hash("composite-scope"),
        key_hash: hash("composite-key"),
        verified: verified,
        max_age: 60,
        clock_skew: 15,
        clock: Clock
      )

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    assert DateTime.compare(claim.issued_at, latest_issued_at) == :eq
    assert claim.expires_at == nil

    assert {:ok, verifier_digest} =
             AshOnetime.Fingerprint.compute(%{
               domain: :nonce_verifiers,
               ordered: ["verifier-a", "verifier-b"]
             })

    assert claim.verifier_id == Base.url_encode64(verifier_digest, padding: false)

    assert DateTime.compare(
             claim.retain_until,
             AshOnetime.Window.cleanup_after(latest_issued_at, 60, 15)
           ) == :eq
  end

  @tag composite_clock_mutation: true
  test "a 3+ sibling composite breaks issued_at ties and collapses expiry unconditionally", %{
    target: target
  } do
    evaluated_at = Clock.now() |> DateTime.truncate(:second)
    tie_at = DateTime.add(evaluated_at, -5, :second)

    # Three siblings, ALL with a non-nil expires_at, two of them tied at the latest issued_at.
    verified = [
      %AshOnetime.Verified{
        key: "s1",
        issued_at: DateTime.add(evaluated_at, -20, :second),
        expires_at: DateTime.add(evaluated_at, 120, :second),
        verifier_id: "verifier-1"
      },
      %AshOnetime.Verified{
        key: "s2",
        issued_at: tie_at,
        expires_at: DateTime.add(evaluated_at, 120, :second),
        verifier_id: "verifier-2"
      },
      %AshOnetime.Verified{
        key: "s3",
        issued_at: tie_at,
        expires_at: DateTime.add(evaluated_at, 120, :second),
        verifier_id: "verifier-3"
      }
    ]

    {:ok, request} =
      Claim.nonce(
        operation_hash: hash("triple-operation"),
        scope_hash: hash("triple-scope"),
        key_hash: hash("triple-key"),
        verified: verified,
        max_age: 120,
        clock_skew: 15,
        clock: Clock
      )

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    # max_by over a tie is deterministic — the latest issued_at is the tie value
    assert DateTime.compare(claim.issued_at, tie_at) == :eq

    # expiry collapses to nil even though EVERY sibling carried a non-nil expires_at
    assert claim.expires_at == nil

    # the verifier digest binds all three siblings, not a truncated subset
    assert {:ok, verifier_digest} =
             AshOnetime.Fingerprint.compute(%{
               domain: :nonce_verifiers,
               ordered: ["verifier-1", "verifier-2", "verifier-3"]
             })

    assert claim.verifier_id == Base.url_encode64(verifier_digest, padding: false)
  end

  test "the retention floor keeps a still-acceptable nonce when the app clock lags the database",
       %{target: target} do
    # Double-spend scenario: the application clock lags the PostgreSQL clock. Freeze the app
    # clock far in the past so the nonce is valid against the acceptance window, while its
    # issuance-based cleanup horizon already sits in the database's past. The retention floor
    # (transaction_timestamp() + margin) must therefore win and keep the nonce retained for the
    # full margin beyond admission — a 1-microsecond floor would let cleanup delete it
    # immediately and let a replay re-admit (double-spend).
    lagging_now = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    Clock.freeze(lagging_now)

    {:ok, request} =
      Claim.nonce(
        operation_hash: hash("floor-operation"),
        scope_hash: hash("floor-scope"),
        key_hash: hash("floor-key"),
        verified: [
          %AshOnetime.Verified{
            key: "floor",
            issued_at: lagging_now,
            expires_at: nil,
            verifier_id: "floor-verifier"
          }
        ],
        max_age: 60,
        clock_skew: 15,
        clock: Clock
      )

    assert {:ok, %Result{status: :admitted, claim: claim}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    margin = AshOnetime.Window.cleanup_skew_margin_seconds()
    assert DateTime.diff(claim.retain_until, claim.admitted_at, :second) == margin
  end

  @tag composite_sibling_mutation: true
  test "one invalid composite nonce sibling rejects the entire admission", %{target: target} do
    evaluated_at = Clock.now() |> DateTime.truncate(:second)

    verified = [
      %AshOnetime.Verified{
        key: "expired-sibling",
        issued_at: DateTime.add(evaluated_at, -120, :second),
        expires_at: DateTime.add(evaluated_at, -90, :second),
        verifier_id: "expired-verifier"
      },
      %AshOnetime.Verified{
        key: "valid-sibling",
        issued_at: DateTime.add(evaluated_at, -1, :second),
        expires_at: nil,
        verifier_id: "valid-verifier"
      }
    ]

    {:ok, request} =
      Claim.nonce(
        operation_hash: hash("invalid-sibling-operation"),
        scope_hash: hash("invalid-sibling-scope"),
        key_hash: hash("invalid-sibling-key"),
        verified: verified,
        max_age: 60,
        clock_skew: 5,
        clock: Clock
      )

    assert {:ok, %Result{status: :failure, reason: :invalid_nonce_window}} =
             Repo.transaction(fn -> Store.claim(target, request) end)
  end

  test "completion and load accept a zero-byte payload", %{target: target} do
    request = idempotency_request("empty-payload")
    digest = :crypto.hash(:sha256, <<>>)

    assert {:ok, %Result{status: :complete, claim: complete, payload: <<>>}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, <<>>)
             end)

    assert complete.response_digest == digest

    assert {:ok, %Result{status: :complete, payload: <<>>}} =
             Repo.transaction(fn -> Store.load(target, complete) end)
  end

  test "completion accepts the Task 2 hard response ceiling exactly", %{target: target} do
    request = idempotency_request("hard-response-ceiling")
    payload = :binary.copy(<<0xA5>>, 16_777_216)
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, payload: stored}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    assert byte_size(stored) == 16_777_216
  end

  # H1 production guard: this is the test that pins the production `load_payload/2`
  # predicate. It seeds a stray payload row in a *different* partition (`~D[2100-01-01]`,
  # which routes to `_default`) and asserts the replay returns the AUTHORITATIVE payload,
  # ignoring the stray. Dropping the `partition_date` predicate from `load_payload/2`
  # makes the read scan all partitions again, see both rows, and return `:corrupt_payload`
  # — which fails this assertion. (Verified RED-then-GREEN: see the registered mutation
  # `partition-pruning-predicate` in scripts/check_mutations.exs.)
  #
  # Partition pruning and cross-partition duplicate detection are mutually exclusive —
  # once the read prunes, a stray payload row in a *different* partition is
  # out-of-partition and invisible to the read. This is the correct behavior, not a hole:
  # the write path (`update_complete`, see "completion rejects cross-partition payload
  # duplication" below at the write-path test) is the authoritative guard that forbids a
  # second payload from ever being written; the cleanup delete guard re-asserts
  # `payload_count = 1` within the authoritative partition (its probe is partition-scoped,
  # mirroring this read-path pruning). A stray row can only exist via direct SQL
  # bypass (operator error / a buggy migration), which the write path already forbids — so
  # the read returning the authoritative payload is right. This test was previously named
  # "load rejects more than one payload row across all partitions" and asserted the
  # now-dropped incidental detection.
  @tag partition_pruning_mutation: true
  test "load prunes to the authoritative partition and ignores an out-of-partition stray", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("load-payload-cardinality")
    payload = "stored"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, claim: complete}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    # A stray row in _default (2100-01-01 is outside the named window) — invisible to a
    # pruning read. Its digest is wrong on purpose; if the read ever returned it, the
    # digest check would catch it. The point is the read must NOT see it at all.
    insert_payload!(prefix, ~D[2100-01-01], complete.id, "extra")

    assert {:ok, %Result{status: :complete, payload: ^payload}} =
             Repo.transaction(fn -> Store.load(target, complete) end)
  end

  # H1 mechanism proof (NOT a production tripwire): this test proves the partition-pruning
  # MECHANISM directly via EXPLAIN — the predicate query shape scans exactly one named
  # child, while the pre-fix claim_id-only shape scans every named child. It does NOT pin
  # production `load_payload/2` (it builds its own SQL via the payload_load_plan helper, so
  # it would stay green if the production predicate were dropped). The behavioral test
  # above is the production guard; this test exists to document and lock the mechanism the
  # fix relies on. First EXPLAIN-based plan assertion in the repo.
  test "the partition_date predicate prunes the payload read to one named child (EXPLAIN)", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("load-payload-pruning")
    payload = "authoritative"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, claim: complete}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    # The install creates months 0..12; roll forward so several named children exist
    # beyond the current month, making a non-pruning scan observable in the plan. Assert the
    # roll succeeded so a silent failure (lock timeout, etc.) does not let the test pass
    # without its distinguishing premise.
    assert {:ok, %{partitions_created: _}} = Store.roll_partitions(target, 15)

    partition = complete.response_partition
    pruned_plan = payload_load_plan(prefix, complete.id, partition, prune?: true)
    unpruned_plan = payload_load_plan(prefix, complete.id, partition, prune?: false)

    named_child_refs = fn plan ->
      Enum.count(plan, fn line ->
        # Count NAMED children only (ash_onetime_response_payloads_YYYY_MM). _default
        # exists on every install and is not evidence of a scan.
        line =~ ~r/ash_onetime_response_payloads_\d{4}_\d{2}/
      end)
    end

    pruned_refs = named_child_refs.(pruned_plan)
    unpruned_refs = named_child_refs.(unpruned_plan)

    # The predicate query (what load_payload/2 executes) prunes to exactly one child.
    assert pruned_refs == 1,
           "expected the pruning query to reference one named child; got #{pruned_refs}.\n" <>
             "plan:\n#{Enum.join(pruned_plan, "\n")}"

    # The pre-fix claim_id-only query scans every named child — proving the predicate is
    # what causes the pruning (the mechanism), not some other planner behavior.
    assert unpruned_refs > 1,
           "expected the non-pruning (claim_id-only) query to scan multiple named children " <>
             "(proving the predicate is load-bearing); got #{unpruned_refs}.\n" <>
             "plan:\n#{Enum.join(unpruned_plan, "\n")}"
  end

  # H1 behavioral regression: a replay after the payload's partition is no longer the
  # newest (N partitions have rolled forward) still returns the correct payload. Guards
  # that the pruning predicate did not break the read contract.
  test "replay returns the authoritative payload after partitions have rolled forward", %{
    target: target
  } do
    request = idempotency_request("load-payload-rolled")
    payload = "rolled-authoritative"
    digest = :crypto.hash(:sha256, payload)

    assert {:ok, %Result{status: :complete, claim: complete}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", digest, payload)
             end)

    # The claim's payload lives in the install-month partition; roll forward so later
    # named partitions exist. The replay must still find the payload in its own partition.
    # Assert the roll succeeded so a silent failure does not let the test pass without its
    # distinguishing premise.
    assert {:ok, %{partitions_created: _}} = Store.roll_partitions(target, 15)

    assert complete.response_partition != nil

    assert {:ok, %Result{status: :complete, payload: ^payload}} =
             Repo.transaction(fn -> Store.load(target, complete) end)
  end

  test "idempotency requests accept only normalized bounded retention seconds" do
    base = [
      operation_hash: hash("retention-operation"),
      scope_hash: hash("retention-scope"),
      key_hash: hash("retention-key"),
      fingerprint: hash("retention-fingerprint")
    ]

    assert {:ok, %Claim.Request{retention_seconds: 2_147_483_647}} =
             Claim.idempotency(Keyword.put(base, :retention_seconds, 2_147_483_647))

    for invalid <- [0, -1, 2_147_483_648, DateTime.utc_now()] do
      assert {:error, :invalid_request} =
               Claim.idempotency(Keyword.put(base, :retention_seconds, invalid))
    end

    assert {:error, :invalid_request} =
             Claim.idempotency(Keyword.put(base, :retain_until, DateTime.utc_now()))
  end

  test "completion rejects a digest mismatch before payload insertion", %{target: target} do
    request = idempotency_request("bad-digest")

    assert {:error,
            %Result{
              status: :failure,
              reason: :invalid_request,
              transaction: :rolled_back
            }} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               Store.complete(target, admitted.claim, "test", hash("other"), "payload")
             end)
  end

  test "every completion failure rolls back claim, guarded effect, and payload", %{
    prefix: prefix,
    target: target
  } do
    create_effect_proof!(prefix)

    failures = [
      {:validation, fn claim -> {claim, "payload", hash("wrong")} end},
      {:payload,
       fn claim ->
         insert_payload!(prefix, Date.utc_today(), claim.id, "existing")
         {claim, "payload", hash("payload")}
       end},
      {:update,
       fn claim ->
         {%{claim | key_hash: hash("different-key")}, "payload", hash("payload")}
       end}
    ]

    for {failure, prepare} <- failures do
      request = idempotency_request("completion-rollback-#{failure}")

      assert {:error, %Result{status: :failure, transaction: :rolled_back}} =
               Repo.transaction(fn ->
                 admitted = Store.claim(target, request)
                 insert_effect!(prefix, Atom.to_string(failure))
                 {claim, payload, digest} = prepare.(admitted.claim)
                 Store.complete(target, claim, "test", digest, payload)
               end)
    end

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
    assert table_count(prefix, "ash_onetime_completion_effects") == 0
  end

  test "completion rejects cross-partition payload duplication and rolls the transaction back", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("payload-cardinality")

    assert {:error, %Result{status: :failure, reason: :store_invariant}} =
             Repo.transaction(fn ->
               admitted = Store.claim(target, request)
               insert_payload!(prefix, ~D[2100-01-01], admitted.claim.id, "extra")
               payload = "authoritative"

               Store.complete(
                 target,
                 admitted.claim,
                 "test",
                 :crypto.hash(:sha256, payload),
                 payload
               )
             end)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
  end

  @tag completion_once_mutation: true
  test "an already-complete claim rejects re-completion with one effect", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("recompletion")
    payload = "authoritative"
    digest = :crypto.hash(:sha256, payload)
    completed = seed_completed_claim!(prefix, request, payload, digest)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 1

    # The completion guard's state predicate (state = 'processing') matches
    # nothing on an already-complete claim, so a second completer turns into
    # store_invariant regardless of which layered guard fires first. No second
    # payload or state mutation lands.
    assert {:error, %Result{status: :failure, reason: :store_invariant}} =
             Repo.transaction(fn ->
               Store.complete(target, completed, "test", digest, payload)
             end)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 1
  end

  @tag completion_once_mutation: true
  test "an already-complete claim rejects an external re-completion", %{
    prefix: prefix,
    target: target
  } do
    request = idempotency_request("recompletion-external")
    payload = "authoritative"
    digest = :crypto.hash(:sha256, payload)
    completed = seed_completed_claim!(prefix, request, payload, digest)

    assert {:error, %Result{status: :failure, reason: :store_invariant}} =
             Repo.transaction(fn ->
               Store.complete_external(target, completed, "test", digest, payload)
             end)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 1
  end

  @tag completion_once_mutation: true
  test "the completion state predicate is the effect-once backstop without a payload", %{
    prefix: prefix,
    target: target
  } do
    # Isolate the state predicate (state = 'processing') in update_complete from
    # the insert_payload conflict guard and the payload-cardinality guard: seed a
    # complete claim with no payload, then attempt completion. insert_payload
    # lands exactly one row, the cardinality and partition checks pass, and only
    # the state predicate (claim is :complete, not :processing) forces the 0-row
    # update into store_invariant. Proves the state guard is a real backstop.
    request = idempotency_request("recompletion-state-backstop")
    payload = "authoritative"
    digest = :crypto.hash(:sha256, payload)
    completed = seed_completed_claim!(prefix, request, payload, digest)

    SQL.query!(
      Repo,
      "DELETE FROM #{relation(prefix, "ash_onetime_response_payloads")} WHERE claim_id = $1::uuid",
      [Ecto.UUID.dump!(request.id)]
    )

    assert {:error, %Result{status: :failure, reason: :store_invariant}} =
             Repo.transaction(fn ->
               Store.complete(target, completed, "test", digest, payload)
             end)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
  end

  test "load reports a missing authoritative claim as a store invariant", %{target: target} do
    request = idempotency_request("missing-load")
    parent = self()

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               result = Store.claim(target, request)
               send(parent, {:rolled_back_claim, result.claim})
               Repo.rollback(:forced_rollback)
             end)

    assert_receive {:rolled_back_claim, claim}

    assert {:ok,
            %Result{
              status: :failure,
              reason: :store_invariant,
              admission_dispatch: :sent,
              transaction: :open
            }} = Repo.transaction(fn -> Store.load(target, claim) end)
  end

  test "catalog has separated strategy columns and exact payload columns", %{prefix: prefix} do
    nonce_columns = columns(prefix, "ash_onetime_nonce_claims")
    payload_columns = columns(prefix, "ash_onetime_response_payloads")

    refute "response_partition" in nonce_columns
    refute "response_codec" in nonce_columns
    refute "response_digest" in nonce_columns
    assert payload_columns == ["claim_id", "encoded_response", "partition_date"]
  end

  test "database rejects malformed hashes and invalid response state", %{prefix: prefix} do
    now = DateTime.utc_now()
    future = DateTime.add(now, 60, :second)
    table = relation(prefix, "ash_onetime_idempotency_claims")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'processing', $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 :binary.copy(<<1>>, 31),
                 hash("s"),
                 hash("k"),
                 hash("f"),
                 now,
                 future
               ]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  response_partition, response_codec, response_digest,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'complete', CURRENT_DATE, 'test', NULL,
                       $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 hash("complete-o"),
                 hash("complete-s"),
                 hash("complete-k"),
                 hash("complete-f"),
                 now,
                 future
               ]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'processing', $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 :binary.copy(<<1>>, 33),
                 hash("s33"),
                 hash("k33"),
                 hash("f33"),
                 now,
                 future
               ]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{table}
                 (id, operation_hash, scope_hash, key_hash, fingerprint, state,
                  response_partition, admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4, $5, 'processing', CURRENT_DATE, $6, $7, $6)
               """,
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 hash("o"),
                 hash("s"),
                 hash("k"),
                 hash("f"),
                 now,
                 future
               ]
             )
  end

  test "nonce timestamp order and payload upper bound are database-enforced", %{prefix: prefix} do
    nonce_table = relation(prefix, "ash_onetime_nonce_claims")
    payload_table = relation(prefix, "ash_onetime_response_payloads")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               """
               INSERT INTO #{nonce_table}
                 (id, operation_hash, scope_hash, key_hash, issued_at, expires_at, verifier_id,
                  admitted_at, retain_until, inserted_at)
               VALUES ($1::uuid, $2, $3, $4,
                       transaction_timestamp(), transaction_timestamp() - interval '1 second', 'test',
                       transaction_timestamp(), transaction_timestamp() + interval '1 hour',
                       transaction_timestamp())
               """,
               [Ecto.UUID.dump!(Ecto.UUID.generate()), hash("no"), hash("ns"), hash("nk")]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO #{payload_table} (partition_date, claim_id, encoded_response) VALUES (CURRENT_DATE, $1::uuid, NULL)",
               [Ecto.UUID.dump!(Ecto.UUID.generate())]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO #{payload_table} (partition_date, claim_id, encoded_response) VALUES (CURRENT_DATE, $1::uuid, $2)",
               [Ecto.UUID.dump!(Ecto.UUID.generate()), :binary.copy(<<0>>, 16_777_217)]
             )

    constraint_sql =
      SQL.query!(
        Repo,
        """
        SELECT string_agg(pg_get_constraintdef(constraint_record.oid), ' ')
        FROM pg_constraint constraint_record
        JOIN pg_class table_record ON table_record.oid = constraint_record.conrelid
        JOIN pg_namespace namespace ON namespace.oid = table_record.relnamespace
        WHERE namespace.nspname = $1 AND table_record.relname = 'ash_onetime_response_payloads'
        """,
        [prefix]
      )
      |> then(fn %{rows: [[definition]]} -> definition end)

    assert constraint_sql =~ "octet_length(encoded_response) <= 16777216"
    refute constraint_sql =~ "octet_length(encoded_response) > 0"
  end

  defp columns(prefix, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2
        ORDER BY column_name
        """,
        [prefix, table]
      )

    Enum.map(rows, &hd/1)
  end

  defp create_effect_proof!(prefix) do
    SQL.query!(
      Repo,
      "CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_completion_effects")} (label text NOT NULL)",
      []
    )
  end

  defp insert_effect!(prefix, label) do
    SQL.query!(
      Repo,
      "INSERT INTO #{relation(prefix, "ash_onetime_completion_effects")} (label) VALUES ($1)",
      [label]
    )
  end

  defp insert_payload!(prefix, date, id, payload) do
    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")}
        (partition_date, claim_id, encoded_response)
      VALUES ($1, $2::uuid, $3)
      """,
      [date, Ecto.UUID.dump!(id), payload]
    )
  end

  # EXPLAIN of the load_payload/2 SELECT shape. `prune?: true` produces the fixed query
  # shape (with the partition_date predicate); `prune?: false` produces the pre-fix
  # claim_id-only shape, to prove the predicate is load-bearing for pruning. Verified on
  # PG 18 (the version test_helper.exs pins) that the parameterized form prunes visibly in
  # the plan text — both the pruned (1 named child) and unpruned (all named children)
  # shapes are observable. Used by the H1 partition-pruning mechanism proof.
  defp payload_load_plan(prefix, claim_id, %Date{} = partition_date, opts) do
    prune? = Keyword.get(opts, :prune?, true)

    {predicate, params} =
      if prune? do
        {"claim_id = $1::uuid AND partition_date = $2",
         [Ecto.UUID.dump!(claim_id), partition_date]}
      else
        {"claim_id = $1::uuid", [Ecto.UUID.dump!(claim_id)]}
      end

    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        EXPLAIN
        SELECT partition_date, encoded_response
        FROM #{relation(prefix, "ash_onetime_response_payloads")}
        WHERE #{predicate}
        """,
        params
      )

    Enum.map(rows, &hd/1)
  end

  # Seeds an already-complete authoritative claim plus its single payload via
  # direct SQL, bypassing Store.complete. This is the "given" state for the
  # re-completion tests: the seeded claim never passes through update_complete,
  # so a mutation of the completion state predicate isolates the re-completion
  # call (the "when") rather than also breaking a first-completion setup step.
  defp seed_completed_claim!(prefix, request, payload, digest) do
    partition_date = Date.utc_today()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    retain_until = DateTime.add(now, 3_600, :second)

    SQL.query!(
      Repo,
      """
      INSERT INTO #{relation(prefix, "ash_onetime_idempotency_claims")}
        (id, operation_hash, scope_hash, key_hash, fingerprint, state,
         response_partition, response_codec, response_digest,
         admitted_at, retain_until, inserted_at)
      VALUES ($1::uuid, $2, $3, $4, $5, 'complete',
              $6, $7, $8, $9, $10, $9)
      """,
      [
        Ecto.UUID.dump!(request.id),
        request.operation_hash,
        request.scope_hash,
        request.key_hash,
        request.fingerprint,
        partition_date,
        "test",
        digest,
        now,
        retain_until
      ]
    )

    insert_payload!(prefix, partition_date, request.id, payload)

    %Claim{
      strategy: :idempotency,
      id: request.id,
      operation_hash: request.operation_hash,
      scope_hash: request.scope_hash,
      key_hash: request.key_hash,
      fingerprint: request.fingerprint,
      state: :complete,
      response_partition: partition_date,
      response_codec: "test",
      response_digest: digest,
      admitted_at: now,
      retain_until: retain_until,
      inserted_at: now
    }
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, table)}", [])
    count
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
