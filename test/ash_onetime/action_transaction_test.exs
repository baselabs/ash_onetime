defmodule AshOnetime.ActionTransactionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Store.Result
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.FaultStore
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_action_examples")} (
        id uuid PRIMARY KEY,
        account_id uuid NOT NULL,
        amount bigint NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_generic_effect_ledger")} (value bigint NOT NULL)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION #{relation(prefix, "observe_ash_onetime_business")}()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO #{relation(prefix, "ash_onetime_action_observations")}
          (kind, claim_id, backend_pid, transaction_id, prefix)
        SELECT 'business', id, pg_backend_pid(), txid_current(), TG_TABLE_SCHEMA
        FROM #{relation(prefix, "ash_onetime_idempotency_claims")}
        ORDER BY inserted_at DESC
        LIMIT 1;
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      DROP TRIGGER IF EXISTS observe_ash_onetime_business
      ON #{relation(prefix, "ash_onetime_action_examples")}
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER observe_ash_onetime_business
      AFTER INSERT ON #{relation(prefix, "ash_onetime_action_examples")}
      FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "observe_ash_onetime_business")}()
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_action_observations")} (
        kind text NOT NULL,
        claim_id uuid NOT NULL,
        backend_pid integer NOT NULL,
        transaction_id bigint NOT NULL,
        prefix text NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION #{relation(prefix, "observe_ash_onetime_claim")}()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO #{relation(prefix, "ash_onetime_action_observations")}
          (kind, claim_id, backend_pid, transaction_id, prefix)
        VALUES ('claim', NEW.id, pg_backend_pid(), txid_current(), TG_TABLE_SCHEMA);
        RETURN NEW;
      END;
      $$
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      DROP TRIGGER IF EXISTS observe_ash_onetime_claim
      ON #{relation(prefix, "ash_onetime_idempotency_claims")}
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER observe_ash_onetime_claim
      AFTER INSERT ON #{relation(prefix, "ash_onetime_idempotency_claims")}
      FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "observe_ash_onetime_claim")}()
      """,
      []
    )

    :ok
  end

  @tag actual_telemetry_mutation: true
  test "actual admission paths emit every closed telemetry family", %{prefix: prefix} do
    events = [
      [:ash_onetime, :admission],
      [:ash_onetime, :conflict],
      [:ash_onetime, :replay],
      [:ash_onetime, :fingerprint_mismatch],
      [:ash_onetime, :verification],
      [:ash_onetime, :encoding],
      [:ash_onetime, :cache],
      [:ash_onetime, :store_uncertainty],
      [:ash_onetime, :untracked_execution]
    ]

    handler = "actual-admission-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _config ->
          send(parent, {:actual_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    key = "telemetry-#{System.unique_integer([:positive])}"
    assert {:ok, 1} = run_generic(prefix, :redeem, %{value: 1, request_key: key})
    assert {:ok, 1} = run_generic(prefix, :redeem, %{value: 1, request_key: key})
    assert {:error, _error} = run_generic(prefix, :redeem, %{value: 2, request_key: key})

    assert {:ok, 3} =
             run_generic(prefix, :consume, %{
               value: 3,
               proof: "telemetry-proof-#{System.unique_integer([:positive])}"
             })

    protection = AshOnetime.Resource.Info.protection(Resource, :redeem)

    input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 4, request_key: "telemetry-fault"})
      |> Ash.ActionInput.set_tenant("fault-tenant")

    AshOnetime.Admission.put_test_store(FaultStore)

    FaultStore.put_result(Result.failure(:lock_timeout, :sent, :rolled_back))

    assert {:error, _error} = AshOnetime.Admission.reserve(input, protection, %{})

    FaultStore.put_result(Result.failure(:checkout_unavailable, :not_started, :not_applicable))

    assert {:execute_untracked, _state} =
             AshOnetime.Admission.reserve(
               input,
               %{protection | on_definite_store_failure: :execute_untracked},
               %{}
             )

    FaultStore.reset()
    AshOnetime.Admission.reset_test_store()

    emitted = drain_actual_telemetry([])
    assert MapSet.new(Enum.map(emitted, &elem(&1, 0))) == MapSet.new(events)

    for {_event, measurements, metadata} <- emitted do
      assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
      assert Map.keys(measurements) in [[:count], [:duration]]
    end
  end

  @tag crud_tuple_mutation: true
  test "CRUD execution, claim, response completion, and replay share one tenant transaction", %{
    prefix: prefix
  } do
    account_id = Ecto.UUID.generate()
    input = charge_input(account_id, 10, "charge-once")

    assert {:ok, first} =
             Resource
             |> Ash.Changeset.for_create(:charge, input)
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create()

    assert {:ok, replayed} =
             Resource
             |> Ash.Changeset.for_create(:charge, input)
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create()

    assert replayed.id == first.id
    assert replayed.account_id == first.account_id
    assert replayed.amount == first.amount
    assert table_count(prefix, "ash_onetime_action_examples") == 1
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 1

    %{rows: observations} =
      SQL.query!(
        Repo,
        "SELECT kind, claim_id::text, backend_pid, transaction_id, prefix FROM #{relation(prefix, "ash_onetime_action_observations")} ORDER BY kind",
        []
      )

    assert [
             ["business", claim_id, backend_pid, transaction_id, ^prefix],
             ["claim", claim_observed_id, claim_backend_pid, claim_transaction_id, ^prefix]
           ] = observations

    assert claim_observed_id == claim_id
    assert claim_backend_pid == backend_pid
    assert claim_transaction_id == transaction_id
  end

  @tag bulk_fallback_mutation: true
  test "protected bulk create falls back to transactional stream execution", %{prefix: prefix} do
    inputs = [
      charge_input(Ecto.UUID.generate(), 10, "bulk-charge-a"),
      charge_input(Ecto.UUID.generate(), 20, "bulk-charge-b")
    ]

    assert %Ash.BulkResult{
             status: :success,
             error_count: 0,
             errors: [],
             records: records
           } =
             Ash.bulk_create(inputs, Resource, :charge,
               tenant: prefix,
               return_records?: true,
               return_errors?: true,
               stop_on_error?: true,
               transaction: :batch,
               batch_size: 2
             )

    assert Enum.map(records, & &1.amount) |> Enum.sort() == [10, 20]
    assert table_count(prefix, "ash_onetime_action_examples") == 2
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 2
    assert table_count(prefix, "ash_onetime_response_payloads") == 2
  end

  @tag replay_execution_mutation: true
  @tag marker_propagation_mutation: true
  test "generic original runs once and its typed stored result replays", %{prefix: prefix} do
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :notify?}, true)
    Process.put({AshOnetime.Test.ActionExamples.Notifier, :observer}, self())

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :notify?})
      Process.delete({AshOnetime.Test.ActionExamples.Notifier, :observer})
    end)

    observer = self()
    arguments = %{value: 42, request_key: "redeem-once"}

    input = fn ->
      Resource
      |> Ash.ActionInput.for_action(:redeem, arguments)
      |> Ash.ActionInput.set_tenant(prefix)
      |> Ash.ActionInput.after_action(fn final_input, value ->
        send(observer, {:replay_marker, AshOnetime.Admission.replay?(final_input)})
        {:ok, value}
      end)
    end

    assert {:ok, 42} =
             input.() |> Ash.run_action()

    assert_receive {:generic_run, %{request_key: "redeem-once", value: 42}}
    assert_receive {:generic_notification, 42}
    assert_receive {:replay_marker, false}

    assert {:ok, 42} =
             input.() |> Ash.run_action()

    refute_receive {:generic_run, _arguments}
    refute_receive {:generic_notification, _value}
    assert_receive {:replay_marker, true}
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
  end

  test "update and destroy replay their stored resource without a second data-layer effect", %{
    prefix: prefix
  } do
    assert {:ok, original} =
             Resource
             |> Ash.Changeset.for_create(
               :charge,
               charge_input(Ecto.UUID.generate(), 10, "seed-for-lifecycle")
             )
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create()

    assert {:ok, updated} =
             original
             |> Ash.Changeset.for_update(:adjust, %{amount: 20, request_key: "adjust-once"})
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.update()

    assert updated.amount == 20

    assert {:ok, replayed_update} =
             original
             |> Ash.Changeset.for_update(:adjust, %{amount: 20, request_key: "adjust-once"})
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.update()

    assert replayed_update.id == original.id
    assert replayed_update.amount == 20

    assert :ok =
             updated
             |> Ash.Changeset.for_destroy(:remove, %{request_key: "remove-once"})
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.destroy(return_destroyed?: false)

    assert {:ok, replayed_destroy} =
             updated
             |> Ash.Changeset.for_destroy(:remove, %{request_key: "remove-once"})
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.destroy(return_destroyed?: true)

    assert replayed_destroy.id == original.id
    assert table_count(prefix, "ash_onetime_action_examples") == 0
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 3
  end

  test "same key with changed declared content is rejected without a second mutation", %{
    prefix: prefix
  } do
    account_id = Ecto.UUID.generate()

    assert {:ok, _first} =
             Resource
             |> Ash.Changeset.for_create(:charge, charge_input(account_id, 10, "mismatch"))
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create()

    assert {:error, error} =
             Resource
             |> Ash.Changeset.for_create(:charge, charge_input(account_id, 11, "mismatch"))
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create()

    assert Exception.message(error) =~ "key was reused with a different request"
    assert table_count(prefix, "ash_onetime_action_examples") == 1
  end

  test "real actions isolate the same key across action and explicit scope namespaces", %{
    prefix: prefix
  } do
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    on_exit(fn -> Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer}) end)

    base = %{value: 12, request_key: "shared-namespace"}

    assert {:ok, 12} = run_generic(prefix, :redeem, base)
    assert {:ok, 12} = run_generic(prefix, :redeem_other, base)

    assert {:ok, 12} =
             run_generic(prefix, :scoped_redeem, Map.put(base, :scope_key, "scope-a"))

    assert {:ok, 12} =
             run_generic(prefix, :scoped_redeem, Map.put(base, :scope_key, "scope-b"))

    assert_receive {:generic_run, _arguments}
    assert_receive {:generic_run, _arguments}
    assert_receive {:generic_run, _arguments}
    assert_receive {:generic_run, _arguments}
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 4
  end

  @tag state_confidentiality_mutation: true
  test "verified nonce admits one generic execution then rejects reuse", %{
    prefix: prefix
  } do
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.StateInspection, :observer}, self())

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.StateInspection, :observer})
    end)

    input = %{value: 9, proof: "nonce-proof"}

    assert {:ok, 9} =
             Resource
             |> Ash.ActionInput.for_action(:consume, input)
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert_receive {:generic_run, %{proof: "nonce-proof", value: 9}}
    assert_receive {:admission_state, {:ok, state}}

    state_bytes = :erlang.term_to_binary(state)
    refute state_bytes =~ "nonce-proof"
    refute state_bytes =~ "action-verifier"
    refute state_bytes =~ "nonce-sensitive-scope"
    assert state.request.verified == nil
    assert state.request.clock == nil
    assert state.claim.verifier_id == nil

    assert {:error, error} =
             Resource
             |> Ash.ActionInput.for_action(:consume, %{input | value: 10})
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert Exception.message(error) =~ "nonce was already used"
    refute_receive {:generic_run, _arguments}
    assert table_count(prefix, "ash_onetime_nonce_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
  end

  test "nonce claims isolate actions and serialize concurrent reuse", %{prefix: prefix} do
    proof = "nonce-concurrent-#{System.unique_integer([:positive])}"

    assert {:ok, 5} = run_generic(prefix, :consume, %{value: 5, proof: proof})
    assert {:ok, 6} = run_generic(prefix, :consume_other, %{value: 6, proof: proof})

    concurrent_proof = "nonce-race-#{System.unique_integer([:positive])}"
    parent = self()

    tasks =
      for value <- [21, 22] do
        task =
          Task.async(fn ->
            receive do
              :go -> run_generic(prefix, :consume, %{value: value, proof: concurrent_proof})
            end
          end)

        Sandbox.allow(AshOnetime.Test.Repo, parent, task.pid)
        task
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _value}, &1)) == 1
    assert Enum.count(results, &match?({:error, _error}, &1)) == 1
    assert table_count(prefix, "ash_onetime_nonce_claims") == 3
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
  end

  @tag corrupt_replay_mutation: true
  test "corrupt authoritative replay is terminal and never repairs by executing again", %{
    prefix: prefix
  } do
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer})
    end)

    input = %{value: 77, request_key: "corrupt-replay"}

    assert {:ok, 77} =
             Resource
             |> Ash.ActionInput.for_action(:redeem, input)
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert_receive {:generic_run, _arguments}

    %{rows: [[claim_id, partition, codec, digest, payload]]} =
      SQL.query!(
        Repo,
        """
        SELECT c.id::text, c.response_partition, c.response_codec, c.response_digest,
               p.encoded_response
        FROM #{relation(prefix, "ash_onetime_idempotency_claims")} c
        JOIN #{relation(prefix, "ash_onetime_response_payloads")} p ON p.claim_id = c.id
        """,
        []
      )

    payload_table = relation(prefix, "ash_onetime_response_payloads")
    claim_table = relation(prefix, "ash_onetime_idempotency_claims")

    SQL.query!(Repo, "UPDATE #{payload_table} SET encoded_response = 'corrupt'", [])
    assert_terminal_replay(prefix, input)
    SQL.query!(Repo, "UPDATE #{payload_table} SET encoded_response = $1", [payload])

    SQL.query!(Repo, "UPDATE #{claim_table} SET response_digest = $1", [
      :crypto.hash(:sha256, "wrong")
    ])

    assert_terminal_replay(prefix, input)
    SQL.query!(Repo, "UPDATE #{claim_table} SET response_digest = $1", [digest])

    SQL.query!(Repo, "UPDATE #{claim_table} SET response_codec = 'wrong-contract'", [])
    assert_terminal_replay(prefix, input)
    SQL.query!(Repo, "UPDATE #{claim_table} SET response_codec = $1", [codec])

    SQL.query!(
      Repo,
      "UPDATE #{claim_table} SET state = 'processing', response_partition = NULL, response_codec = NULL, response_digest = NULL",
      []
    )

    assert_terminal_replay(prefix, input)

    SQL.query!(
      Repo,
      "UPDATE #{claim_table} SET state = 'complete', response_partition = $1, response_codec = $2, response_digest = $3",
      [partition, codec, digest]
    )

    SQL.query!(Repo, "DELETE FROM #{payload_table}", [])
    assert_terminal_replay(prefix, input)

    SQL.query!(
      Repo,
      "INSERT INTO #{payload_table} (partition_date, claim_id, encoded_response) VALUES ($1, $2::uuid, $3)",
      [partition, Ecto.UUID.dump!(claim_id), payload]
    )

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 1
  end

  @tag untracked_siblings_mutation: true
  test "exact checkout failure executes untracked only for opted-in idempotency" do
    protection = AshOnetime.Resource.Info.protection(Resource, :redeem)

    input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 4, request_key: "fault"})
      |> Ash.ActionInput.set_tenant("fault-tenant")

    FaultStore.put_result(Result.failure(:checkout_unavailable, :not_started, :not_applicable))

    AshOnetime.Admission.put_test_store(FaultStore)

    on_exit(fn ->
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
    end)

    assert {:error, %AshOnetime.Error{code: :checkout_unavailable}} =
             AshOnetime.Admission.reserve(input, protection, %{})

    opted_in = %{protection | on_definite_store_failure: :execute_untracked}

    assert {:execute_untracked, %{class: :untracked}} =
             AshOnetime.Admission.reserve(input, opted_in, %{})

    for failure <- [
          Result.failure(:lock_timeout, :sent, :rolled_back),
          Result.failure(:disconnected, :unknown, :unknown),
          Result.failure(:dispatched_unknown, :unknown, :unknown)
        ] do
      FaultStore.put_result(failure)

      assert {:error, %AshOnetime.Error{code: code}} =
               AshOnetime.Admission.reserve(input, opted_in, %{})

      assert code == failure.reason
    end
  end

  test "sent and ambiguous store failures fail closed for generic and nonce directions" do
    idempotency = AshOnetime.Resource.Info.protection(Resource, :redeem)

    generic =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 4, request_key: "fault"})
      |> Ash.ActionInput.set_tenant("fault-tenant")

    nonce = AshOnetime.Resource.Info.protection(Resource, :consume)

    nonce_input =
      Resource
      |> Ash.ActionInput.for_action(:consume, %{value: 4, proof: "fault"})
      |> Ash.ActionInput.set_tenant("fault-tenant")

    AshOnetime.Admission.put_test_store(FaultStore)

    on_exit(fn ->
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
    end)

    for failure <- [
          Result.failure(:lock_timeout, :sent, :rolled_back),
          Result.failure(:disconnected, :unknown, :unknown),
          Result.failure(:dispatched_unknown, :unknown, :unknown)
        ] do
      FaultStore.put_result(failure)

      assert {:error, %AshOnetime.Error{code: code}} =
               AshOnetime.Admission.reserve(generic, idempotency, %{})

      assert code == failure.reason

      assert {:error, %AshOnetime.Error{code: nonce_code}} =
               AshOnetime.Admission.reserve(nonce_input, nonce, %{})

      assert nonce_code == failure.reason
    end
  end

  @tag completion_transaction_mutation: true
  test "completion outside the caller transaction fails before changing authoritative state", %{
    prefix: prefix
  } do
    protection = AshOnetime.Resource.Info.protection(Resource, :redeem)

    input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{
        value: 41,
        request_key: "outside-completion-transaction"
      })
      |> Ash.ActionInput.set_tenant(prefix)

    assert {:ok, {:execute, state}} =
             Repo.transaction(fn -> AshOnetime.Admission.reserve(input, protection, %{}) end)

    assert {:error, %AshOnetime.Error{code: :store_invariant}} =
             AshOnetime.Admission.complete(state, 41)

    assert table_count(prefix, "ash_onetime_idempotency_claims") == 1
    assert table_count(prefix, "ash_onetime_response_payloads") == 0

    assert %{rows: [["processing"]]} =
             SQL.query!(
               Repo,
               "SELECT state FROM #{relation(prefix, "ash_onetime_idempotency_claims")}",
               []
             )
  end

  test "real CRUD generic and nonce adapters preserve every store fault direction", %{
    prefix: prefix
  } do
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    AshOnetime.Admission.put_test_store(FaultStore)

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer})
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
    end)

    checkout =
      Result.failure(:checkout_unavailable, :not_started, :not_applicable)

    FaultStore.put_result(checkout)

    assert {:error, _error} =
             Resource
             |> Ash.Changeset.for_create(
               :charge,
               charge_input(Ecto.UUID.generate(), 10, "crud-checkout")
             )
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create()

    assert {:error, _error} =
             run_generic(prefix, :redeem, %{value: 8, request_key: "generic-checkout"})

    assert {:error, _error} =
             run_generic(prefix, :consume, %{value: 8, proof: "nonce-checkout"})

    refute_receive {:generic_run, _arguments}
    assert table_count(prefix, "ash_onetime_action_examples") == 0

    for fault <- [
          Result.failure(:lock_timeout, :sent, :rolled_back),
          Result.failure(:disconnected, :unknown, :unknown),
          Result.failure(:dispatched_unknown, :unknown, :unknown)
        ] do
      FaultStore.put_result(fault)

      assert {:error, _error} =
               run_generic(prefix, :redeem, %{
                 value: 9,
                 request_key: "generic-#{fault.reason}"
               })

      assert {:error, _error} =
               Resource
               |> Ash.Changeset.for_create(
                 :charge,
                 charge_input(Ecto.UUID.generate(), 10, "crud-#{fault.reason}")
               )
               |> Ash.Changeset.set_tenant(prefix)
               |> Ash.create()

      assert {:error, _error} =
               run_generic(prefix, :consume, %{value: 9, proof: "nonce-#{fault.reason}"})
    end

    refute_receive {:generic_run, _arguments}
    assert table_count(prefix, "ash_onetime_action_examples") == 0
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_nonce_claims") == 0
  end

  @tag claim_identity_mutation: true
  @tag fingerprint_identity_mutation: true
  test "mutated admitted claim identity never grants execution" do
    protection = AshOnetime.Resource.Info.protection(Resource, :redeem)

    input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 4, request_key: "identity"})
      |> Ash.ActionInput.set_tenant("fault-tenant")

    AshOnetime.Admission.put_test_store(FaultStore)

    on_exit(fn ->
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
    end)

    mutations = [
      &%{&1 | strategy: :one_time_nonce},
      &%{&1 | id: Ecto.UUID.generate()},
      &%{&1 | operation_hash: :crypto.hash(:sha256, "wrong-operation")},
      &%{&1 | scope_hash: :crypto.hash(:sha256, "wrong-scope")},
      &%{&1 | key_hash: :crypto.hash(:sha256, "wrong-key")},
      &%{&1 | fingerprint: :crypto.hash(:sha256, "wrong-fingerprint")},
      &%{&1 | state: :complete}
    ]

    for mutation <- mutations do
      FaultStore.put_handler(fn
        :claim, [_target, request] ->
          now = DateTime.utc_now()

          claim = %AshOnetime.Store.Claim{
            strategy: request.strategy,
            id: request.id,
            operation_hash: request.operation_hash,
            scope_hash: request.scope_hash,
            key_hash: request.key_hash,
            fingerprint: request.fingerprint,
            state: :processing,
            admitted_at: now,
            retain_until: DateTime.add(now, 60, :second),
            inserted_at: now
          }

          Result.success(:admitted, claim: mutation.(claim))
      end)

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               AshOnetime.Admission.reserve(input, protection, %{})
    end
  end

  @tag completion_mutation: true
  test "completion failure rolls back a generic effect through the real wrapper", %{
    prefix: prefix
  } do
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :ledger?}, true)
    AshOnetime.Admission.put_test_store(FaultStore)

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :ledger?})
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
    end)

    FaultStore.put_handler(fn
      :claim, [_target, request] ->
        Result.success(:admitted, claim: exact_processing_claim(request))

      :complete, _arguments ->
        Result.failure(:store_invariant, :sent, :rolled_back)
    end)

    assert {:error, _error} =
             Resource
             |> Ash.ActionInput.for_action(:redeem, %{value: 31, request_key: "complete-fault"})
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert_receive {:generic_run, _arguments}
    assert table_count(prefix, "ash_onetime_generic_effect_ledger") == 0
  end

  @tag completion_invariant_rollback_mutation: true
  test "a real completion invariant rolls back claim, payload, and effect through the Ash pipeline",
       %{
         prefix: prefix
       } do
    # Inject a cross-partition payload row inside the Ash caller transaction via a
    # trigger on claim INSERT, so the real Store.complete/5 hits its 1-payload
    # cardinality guard (update_complete) and returns store_invariant. Unlike the
    # FaultStore mock, this drives real PostgreSQL rollback through Ash.run_action
    # -> Admission.complete -> Store.complete, unwinding the authoritative claim,
    # both payload rows, and the CRUD business record together.
    SQL.query!(
      Repo,
      """
      CREATE OR REPLACE FUNCTION #{relation(prefix, "poison_payload_on_claim")}()
      RETURNS trigger LANGUAGE plpgsql AS $poison$
      BEGIN
        INSERT INTO #{relation(prefix, "ash_onetime_response_payloads")}
          (partition_date, claim_id, encoded_response)
        VALUES ('2100-01-01', NEW.id, 'poison');
        RETURN NEW;
      END
      $poison$
      """,
      []
    )

    SQL.query!(
      Repo,
      "DROP TRIGGER IF EXISTS poison_payload_on_claim ON #{relation(prefix, "ash_onetime_idempotency_claims")}",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER poison_payload_on_claim
      AFTER INSERT ON #{relation(prefix, "ash_onetime_idempotency_claims")}
      FOR EACH ROW EXECUTE FUNCTION #{relation(prefix, "poison_payload_on_claim")}()
      """,
      []
    )

    try do
      account_id = Ecto.UUID.generate()

      assert {:error, error} =
               Resource
               |> Ash.Changeset.for_create(
                 :charge,
                 charge_input(account_id, 10, "poisoned-completion")
               )
               |> Ash.Changeset.set_tenant(prefix)
               |> Ash.create()

      # Pin the code the completion invariant surfaces to the caller (P1-2): an unrelated
      # failure that also rolled everything back to zero must not satisfy this test for the
      # wrong reason. Through the full Ash pipeline the store's `store_invariant` is caught as
      # the Ecto rollback unwinds and normalized to `:response_completion_failed`
      # (admission.ex:139/142) — the store-level tests see the raw `:store_invariant`. This
      # pins the true caller contract and proves the typed code survives the pipeline (ARCH-1).
      assert AshOnetime.Error.code(error) == :response_completion_failed

      assert table_count(prefix, "ash_onetime_action_examples") == 0
      assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
      assert table_count(prefix, "ash_onetime_response_payloads") == 0
    after
      SQL.query!(
        Repo,
        "DROP TRIGGER IF EXISTS poison_payload_on_claim ON #{relation(prefix, "ash_onetime_idempotency_claims")}",
        []
      )

      SQL.query!(
        Repo,
        "DROP FUNCTION IF EXISTS #{relation(prefix, "poison_payload_on_claim")}()",
        []
      )
    end
  end

  @tag completion_identity_mutation: true
  test "completion validates every local encoding and outer evidence field" do
    protection = AshOnetime.Resource.Info.protection(Resource, :redeem)

    input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 4, request_key: "completion-identity"})
      |> Ash.ActionInput.set_tenant("fault-tenant")

    AshOnetime.Admission.put_test_store(FaultStore)

    on_exit(fn ->
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
    end)

    FaultStore.put_handler(fn
      :claim, [_target, request] ->
        Result.success(:admitted, claim: exact_processing_claim(request))
    end)

    assert {:execute, state} = AshOnetime.Admission.reserve(input, protection, %{})
    assert {:ok, encoded} = AshOnetime.Response.encode(4, state.contract, [])

    complete_claim = %{
      state.claim
      | state: :complete,
        response_partition: ~D[2000-01-01],
        response_codec: encoded.codec,
        response_digest: encoded.digest
    }

    exact =
      Result.success(:complete,
        claim: complete_claim,
        payload: encoded.payload
      )

    malformed = [
      %{exact | claim: %{complete_claim | response_codec: "wrong"}},
      %{exact | claim: %{complete_claim | response_digest: :crypto.hash(:sha256, "wrong")}},
      %{exact | payload: "wrong"},
      %{exact | claim: %{complete_claim | response_partition: "2000-01-01"}},
      %{exact | claim: %{complete_claim | state: :processing}},
      %{exact | status: :processing, payload: nil},
      %{exact | reason: :store_invariant},
      %{exact | admission_dispatch: :unknown},
      %{exact | transaction: :rolled_back},
      %{exact | claim: nil},
      %{exact | payload: nil}
    ]

    for completion <- malformed do
      FaultStore.put_handler(fn
        :complete, _arguments -> completion
      end)

      assert {:error, %AshOnetime.Error{code: :store_invariant}} =
               AshOnetime.Admission.complete(state, 4)
    end

    FaultStore.put_handler(fn
      :complete, _arguments -> exact
    end)

    assert {:ok, 4} = AshOnetime.Admission.complete(state, 4)
  end

  @tag completion_partition_clock_mutation: true
  test "completion trusts the PostgreSQL transaction date across an application date boundary", %{
    prefix: prefix
  } do
    assert {:ok, :completed} =
             Repo.transaction(fn ->
               application_date = Date.utc_today()

               timezone =
                 Enum.find(["Etc/GMT+12", "Pacific/Kiritimati"], fn timezone ->
                   %{rows: [[database_date]]} =
                     SQL.query!(
                       Repo,
                       "SELECT (transaction_timestamp() AT TIME ZONE $1)::date",
                       [timezone]
                     )

                   database_date != application_date
                 end)

               assert is_binary(timezone)
               SQL.query!(Repo, "SELECT set_config('TimeZone', $1, true)", [timezone])

               assert %{rows: [[database_date]]} =
                        SQL.query!(Repo, "SELECT transaction_timestamp()::date", [])

               refute database_date == application_date

               assert {:ok, _record, _notifications} =
                        Resource
                        |> Ash.Changeset.for_create(
                          :charge,
                          charge_input(
                            Ecto.UUID.generate(),
                            10,
                            "database-transaction-date"
                          )
                        )
                        |> Ash.Changeset.set_tenant(prefix)
                        |> Ash.create(return_notifications?: true)

               assert %{rows: [[^database_date]]} =
                        SQL.query!(
                          Repo,
                          "SELECT response_partition FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE state = 'complete'",
                          []
                        )

               :completed
             end)
  end

  test "package completion remains last after a replay-aware generic transformation" do
    protection = AshOnetime.Resource.Info.protection(Resource, :redeem)

    input =
      %Ash.ActionInput{
        resource: Resource,
        action: Ash.Resource.Info.action(Resource, :redeem),
        arguments: %{value: 5, request_key: "final-transform"},
        context: %{private: %{}}
      }
      |> Ash.ActionInput.after_action(fn final_input, value ->
        if AshOnetime.Admission.replay?(final_input), do: {:ok, value}, else: {:ok, value + 1}
      end)
      |> AshOnetime.GenericAction.prepare(
        [protection: protection],
        %Ash.Resource.Preparation.Context{}
      )

    [transform, package_complete] = input.after_action
    execute = AshOnetime.Admission.put_test_state(input, :untracked)
    assert {:ok, 6} = transform.(execute, 5)
    assert {:ok, 6} = package_complete.(execute, 6)

    replay = AshOnetime.Admission.put_test_state(input, :replay, 6)
    assert {:ok, 6} = transform.(replay, 6)
    assert {:ok, 6} = package_complete.(replay, 6)
  end

  test "late CRUD and generic hook failures roll back claims, payloads, and effects", %{
    prefix: prefix
  } do
    changeset =
      Resource
      |> Ash.Changeset.for_create(
        :charge,
        charge_input(Ecto.UUID.generate(), 10, "late-crud-failure")
      )
      |> Ash.Changeset.set_tenant(prefix)
      |> Ash.Changeset.after_action(fn _changeset, _result -> {:error, "late CRUD failure"} end)

    assert {:error, _error} = Ash.create(changeset)
    assert table_count(prefix, "ash_onetime_action_examples") == 0
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
    assert table_count(prefix, "ash_onetime_action_observations") == 0

    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :ledger?}, true)
    on_exit(fn -> Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :ledger?}) end)

    action_input =
      Resource
      |> Ash.ActionInput.for_action(:redeem, %{value: 8, request_key: "late-generic-failure"})
      |> Ash.ActionInput.set_tenant(prefix)
      |> Ash.ActionInput.after_action(fn _input, _result -> {:error, "late generic failure"} end)

    assert {:error, _error} = Ash.run_action(action_input)
    assert table_count(prefix, "ash_onetime_generic_effect_ledger") == 0
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
    assert table_count(prefix, "ash_onetime_response_payloads") == 0
  end

  # M1 (closeout fix): the bounded callback context is EXACTLY %{resource:, action:}. The
  # prior admission_test pin (module_info(:functions) absence) was vacuous. This asserts the
  # production bounded_callback_context/1 (the function the three call sites — scope :439,
  # verify :521, mint :552 — pass to their callbacks) returns exactly %{resource:, action:}
  # for a real ActionInput. No DB, no Ash action machinery → deterministic under full-suite
  # load. A regression that re-forwards caller context (actor/tenant/keys/now) into the
  # bounded context fails this test.
  @tag bounded_callback_context_contract: true
  test "the bounded callback context carries exactly resource and action (M1)" do
    subject = Ash.ActionInput.for_action(Resource, :consume, %{value: 1, proof: "m1-direct"})
    context = AshOnetime.Admission.bounded_callback_context(subject)

    # The context a verifier/mint/scope callback receives is exactly %{resource:, action:}.
    assert Enum.sort(Map.keys(context)) == [:action, :resource]
    assert context.resource == Resource
    assert context.action == :consume
  end

  defp charge_input(account_id, amount, request_key) do
    %{
      account_id: account_id,
      amount: amount,
      request_key: request_key,
      natural_key: "natural-#{request_key}",
      external_key: "external-#{request_key}"
    }
  end

  defp run_generic(prefix, action, arguments) do
    Resource
    |> Ash.ActionInput.for_action(action, arguments)
    |> Ash.ActionInput.set_tenant(prefix)
    |> Ash.run_action()
  end

  defp assert_terminal_replay(prefix, input) do
    assert {:error, _error} =
             Resource
             |> Ash.ActionInput.for_action(:redeem, input)
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    refute_receive {:generic_run, _arguments}
  end

  defp drain_actual_telemetry(events) do
    receive do
      {:actual_telemetry, event, measurements, metadata} ->
        drain_actual_telemetry([{event, measurements, metadata} | events])
    after
      100 -> Enum.reverse(events)
    end
  end

  defp exact_processing_claim(request) do
    now = DateTime.utc_now()

    %AshOnetime.Store.Claim{
      strategy: request.strategy,
      id: request.id,
      operation_hash: request.operation_hash,
      scope_hash: request.scope_hash,
      key_hash: request.key_hash,
      fingerprint: request.fingerprint,
      state: :processing,
      admitted_at: now,
      retain_until: DateTime.add(now, 60, :second),
      inserted_at: now
    }
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, table)}", [])
    count
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
