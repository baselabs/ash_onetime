defmodule AshOnetime.System.ExternalRecoveryTest do
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
    repo = start_unboxed_repo!()
    ExternalEffectSupport.reset_mode()
    on_exit(&ExternalEffectSupport.reset_mode/0)
    {:ok, external_repo: repo}
  end

  @tag ambiguous_external_retry_mutation: true
  test "peer success followed by caller death recovers without another execute", context do
    reference = make_ref()

    {worker, monitor} =
      run_worker(context, {:pause_after_execute, self(), reference}, "system-crash", 11)

    assert_receive {:external_pause, ^reference, :after_execute, operation_key, ^worker}, 5_000
    assert [["execute", ^operation_key]] = ExternalPeer.calls(context.prefix)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000

    assert {:ok, 11} = run(context, "system-crash", 11)

    assert [["execute", ^operation_key], ["recover", ^operation_key]] =
             ExternalPeer.calls(context.prefix)

    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 1
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 1
  end

  test "ambiguous recovery remains processing and never retries the peer effect", context do
    operation_key = leave_processing(context, "system-ambiguous", 12)
    ExternalEffectSupport.put_mode(:recover_unknown)

    assert {:error, error} = run(context, "system-ambiguous", 12)
    assert Exception.message(error) =~ "external effect outcome is unknown"
    assert [["recover", ^operation_key]] = ExternalPeer.calls(context.prefix)
    assert ExternalPeer.count(context.prefix, "external_peer_effects") == 0
    assert ExternalPeer.count(context.prefix, "external_local_effects") == 0
    assert claim_state(context.prefix, operation_key) == "processing"
  end

  defp run(context, request_key, value) do
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

  defp run_worker(context, mode, request_key, value) do
    parent = self()

    spawn_monitor(fn ->
      ExternalEffectSupport.put_mode(mode)
      send(parent, {:external_result, self(), run(context, request_key, value)})
    end)
  end

  defp leave_processing(context, request_key, value) do
    reference = make_ref()

    {worker, monitor} =
      run_worker(context, {:pause_before_execute, self(), reference}, request_key, value)

    assert_receive {:external_pause, ^reference, :before_execute, operation_key, ^worker}, 5_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
    operation_key
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
