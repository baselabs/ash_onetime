defmodule AshOnetime.ExternalRecoveryTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.{ExternalEffectSupport, ExternalPeer}

  @moduletag unboxed: true

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    ExternalPeer.install!(prefix)
    create_crud_table!(prefix)
    repo = start_unboxed_repo!()
    ExternalEffectSupport.reset_mode()
    on_exit(&ExternalEffectSupport.reset_mode/0)
    {:ok, external_repo: repo}
  end

  @tag external_commit_mutation: true
  test "a processing recovery point commits before any peer work", %{
    target: target,
    external_repo: repo
  } do
    request = idempotency_request("external-commit")
    target = %{target | dynamic_repo: repo}

    assert %Result{
             status: :admitted,
             transaction: :committed,
             claim: %Claim{state: :processing}
           } = Store.claim_committed(target, request)
  end

  @tag external_recover_mutation: true
  @tag external_operation_key_mutation: true
  test "caller death before peer preserves one key and retry proves absence", context do
    reference = make_ref()

    {worker, monitor} =
      run_worker(context, {:pause_before_execute, self(), reference}, "crash-before", 10)

    assert_receive {:external_pause, ^reference, :before_execute, operation_key, ^worker}, 5_000
    assert claim_state(context.prefix, operation_key) == "processing"
    assert ExternalPeer.calls(context.prefix) == []

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000

    result = run_generic(context, "crash-before", 10)

    assert [["recover", ^operation_key], ["execute", ^operation_key]] =
             ExternalPeer.calls(context.prefix)

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert {:ok, 10} = result
    assert claim_state(context.prefix, operation_key) == "complete"
  end

  @tag external_recover_mutation: true
  @tag external_operation_key_mutation: true
  test "peer success followed by caller death recovers without another execute", context do
    reference = make_ref()

    {worker, monitor} =
      run_worker(context, {:pause_after_execute, self(), reference}, "crash-after", 11)

    assert_receive {:external_pause, ^reference, :after_execute, operation_key, ^worker}, 5_000
    assert [["execute", ^operation_key]] = ExternalPeer.calls(context.prefix)
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000

    result = run_generic(context, "crash-after", 11)

    assert [["execute", ^operation_key], ["recover", ^operation_key]] =
             ExternalPeer.calls(context.prefix)

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert {:ok, 11} = result
  end

  @tag external_recover_mutation: true
  test "unknown execute is recovered once immediately", context do
    ExternalEffectSupport.put_mode(:unknown_after_execute)

    result = run_generic(context, "unknown-execute", 12)

    assert [["execute", operation_key], ["recover", operation_key]] =
             ExternalPeer.calls(context.prefix)

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
    assert {:ok, 12} = result
  end

  @tag ambiguous_retry_mutation: true
  test "ambiguous recovery never executes or finalizes", context do
    operation_key = leave_processing_before_peer(context, "ambiguous", 13)
    calls_before = ExternalPeer.calls(context.prefix)
    ExternalEffectSupport.put_mode(:recover_unknown)

    result = run_generic(context, "ambiguous", 13)

    assert ExternalPeer.calls(context.prefix) == calls_before ++ [["recover", operation_key]]
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 0
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0
    assert {:error, error} = result
    assert Exception.message(error) =~ "external effect outcome is unknown"
    assert claim_state(context.prefix, operation_key) == "processing"
  end

  @tag ambiguous_retry_mutation: true
  test "ambiguous outcome from an unknown execute and recover never executes or finalizes",
       context do
    # Path D of the double-execute firewall: a fresh admission reaches
    # execute_then_settle, execute runs at the peer but returns :outcome_unknown,
    # and the immediate recover returns :unknown. The claim must settle to
    # {:error, :outcome_unknown}. Execute's evidence lands once (it ran), but
    # finalize never runs, so there is no local effect and no second execute.
    ExternalEffectSupport.put_mode(:execute_unknown_recover_unknown)

    result = run_generic(context, "ambiguous-execute", 19)

    assert [["execute", operation_key], ["recover", operation_key]] =
             ExternalPeer.calls(context.prefix)

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0
    assert {:error, error} = result
    assert Exception.message(error) =~ "external effect outcome is unknown"
    assert claim_state(context.prefix, operation_key) == "processing"
  end

  test "local finalization rollback leaves peer result recoverable", context do
    ExternalEffectSupport.put_mode(:fail_local)

    assert {:error, _error} = run_generic(context, "local-rollback", 14)
    assert [["execute", operation_key]] = ExternalPeer.calls(context.prefix)
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0
    assert claim_state(context.prefix, operation_key) == "processing"

    ExternalEffectSupport.reset_mode()
    assert {:ok, 14} = run_generic(context, "local-rollback", 14)

    assert [["execute", ^operation_key], ["recover", ^operation_key]] =
             ExternalPeer.calls(context.prefix)

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
  end

  test "completed generic and CRUD requests replay without any peer or local effect", context do
    assert {:ok, 15} = run_generic(context, "replay-generic", 15)
    snapshot = evidence_counts(context.prefix)
    assert {:ok, 15} = run_generic(context, "replay-generic", 15)
    assert evidence_counts(context.prefix) == snapshot

    account_id = Ecto.UUID.generate()
    assert {:ok, first} = run_crud(context, "replay-crud", account_id, 16)
    snapshot = evidence_counts(context.prefix)
    assert {:ok, replayed} = run_crud(context, "replay-crud", account_id, 16)
    assert replayed.id == first.id
    assert replayed.amount == first.amount
    assert evidence_counts(context.prefix) == snapshot
  end

  test "unexpected execute faults are contained and recovered only after evidence", context do
    for {mode, suffix} <- [
          {:raise_execute, "raise"},
          {:throw_execute, "throw"},
          {:exit_execute, "exit"},
          {:invalid_execute, "invalid"}
        ] do
      ExternalEffectSupport.put_mode(mode)
      assert {:error, error} = run_generic(context, "fault-#{suffix}", 17)
      assert Exception.message(error) =~ "external effect did not produce an outcome"
    end

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 0
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0
  end

  test "external telemetry is value-free and closed", context do
    handler = "external-recovery-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ash_onetime, :external_recovery],
        fn event, measurements, metadata, _config ->
          send(parent, {:external_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, 18} = run_generic(context, "telemetry", 18)

    events = drain_telemetry([])
    assert events != []

    for {event, measurements, metadata} <- events do
      assert event == [:ash_onetime, :external_recovery]
      assert Map.keys(measurements) == [:duration]
      assert Map.keys(metadata) |> Enum.sort() == [:action, :resource, :result_class, :strategy]
      assert metadata.strategy == :idempotency
      refute inspect({measurements, metadata}) =~ "telemetry"
    end
  end

  test "external completion restarts retention from database statement time", context do
    reference = make_ref()

    {worker, monitor} =
      run_worker(context, {:pause_after_execute, self(), reference}, "retention", 20)

    assert_receive {:external_pause, ^reference, :after_execute, operation_key, ^worker}, 5_000
    SQL.query!(Repo, "SELECT pg_sleep(0.05)", [])
    send(worker, {:external_continue, reference})
    assert_receive {:external_action_result, ^worker, {:ok, 20}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000

    %{rows: [[from_admission, from_statement]]} =
      SQL.query!(
        Repo,
        """
        SELECT extract(epoch FROM retain_until - admitted_at)::float8,
               extract(epoch FROM retain_until - statement_timestamp())::float8
        FROM #{relation(context.prefix, "ash_onetime_idempotency_claims")}
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(operation_key)]
      )

    assert from_admission > 3_600.04
    assert from_statement > 3_599.0
    assert from_statement <= 3_600.0
  end

  defp run_generic(context, request_key, value) do
    with_dynamic_repo(context.external_repo, fn ->
      Resource
      |> Ash.ActionInput.for_action(:external_redeem, %{
        value: value,
        request_key: request_key,
        proof: "proof-#{request_key}"
      })
      |> Ash.ActionInput.set_tenant(context.prefix)
      |> Ash.run_action()
    end)
  end

  defp run_crud(context, request_key, account_id, amount) do
    with_dynamic_repo(context.external_repo, fn ->
      Resource
      |> Ash.Changeset.for_create(:external_charge, %{
        account_id: account_id,
        amount: amount,
        request_key: request_key,
        proof: "proof-#{request_key}"
      })
      |> Ash.Changeset.set_tenant(context.prefix)
      |> Ash.create()
    end)
  end

  defp run_worker(context, mode, request_key, value) do
    parent = self()

    spawn_monitor(fn ->
      ExternalEffectSupport.put_mode(mode)
      send(parent, {:external_action_result, self(), run_generic(context, request_key, value)})
    end)
  end

  defp leave_processing_before_peer(context, request_key, value) do
    reference = make_ref()

    {worker, monitor} =
      run_worker(context, {:pause_before_execute, self(), reference}, request_key, value)

    assert_receive {:external_pause, ^reference, :before_execute, operation_key, ^worker}, 5_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
    operation_key
  end

  defp create_crud_table!(prefix) do
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
  end

  defp claim_state(prefix, operation_key) do
    %{rows: [[state]]} =
      SQL.query!(
        Repo,
        "SELECT state FROM #{relation(prefix, "ash_onetime_idempotency_claims")} WHERE id = $1::uuid",
        [Ecto.UUID.dump!(operation_key)]
      )

    state
  end

  defp evidence_counts(prefix) do
    for table <- ["external_peer_calls", "external_peer_effects", "external_local_effects"],
        into: %{} do
      {table, ExternalPeer.count(prefix, table)}
    end
  end

  defp drain_telemetry(events) do
    receive do
      {:external_telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp with_dynamic_repo(repo, callback) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      callback.()
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
