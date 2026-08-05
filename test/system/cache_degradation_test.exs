defmodule AshOnetime.System.CacheDegradationTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Cache.Entry
  alias AshOnetime.Store.Result
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.{Cache, FaultStore}

  @moduletag :system

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    SQL.query!(
      Repo,
      "CREATE TABLE IF NOT EXISTS #{relation(prefix, "ash_onetime_generic_effect_ledger")} (value bigint NOT NULL)",
      []
    )

    previous_cache = Application.get_env(:ash_onetime, :cache)
    previous_timeout = Application.get_env(:ash_onetime, :cache_timeout)
    Cache.start()
    Application.put_env(:ash_onetime, :cache, Cache)
    Application.put_env(:ash_onetime, :cache_timeout, 10)
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :ledger?}, true)

    on_exit(fn ->
      restore_env(:cache, previous_cache)
      restore_env(:cache_timeout, previous_timeout)
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :ledger?})
      FaultStore.reset()
      AshOnetime.Admission.reset_test_store()
      Cache.reset()
    end)

    :ok
  end

  @tag system_digest_bypass_mutation: true
  test "poison, stale payload, circuit, timeout, and corruption degrade to PostgreSQL", %{
    prefix: prefix
  } do
    key = "system-poison"
    assert {:ok, 41} = run(prefix, key, 41)
    [{{:entry, _cache_key}, %Entry{} = authoritative, _ttl}] = Cache.entries()

    Cache.poison(%{authoritative | payload: "stale-payload"})
    assert {:ok, 41} = run(prefix, key, 41)

    for mode <- [:circuit_open, :timeout, :corrupt] do
      Cache.mode(:normal)
      request_key = "system-cache-#{mode}"
      assert {:ok, 17} = run(prefix, request_key, 17)
      Cache.mode(mode)
      assert {:ok, 17} = run(prefix, request_key, 17)
    end

    assert ledger_count(prefix) == 4
  end

  @tag system_cache_admission_mutation: true
  test "cache presence cannot admit when authoritative PostgreSQL rejects", %{prefix: prefix} do
    AshOnetime.Admission.put_test_store(FaultStore)
    FaultStore.put_result(Result.failure(:lock_timeout, :sent, :rolled_back))

    assert {:error, _error} = run(prefix, "cache-must-not-admit", 99)
    assert ledger_count(prefix) == 0
  end

  test "cache state cannot reject or admit a nonce", %{prefix: prefix} do
    Cache.mode(:circuit_open)
    proof = "system-cache-nonce"

    assert {:ok, 7} =
             Resource
             |> Ash.ActionInput.for_action(:consume, %{value: 7, proof: proof})
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert {:error, _error} =
             Resource
             |> Ash.ActionInput.for_action(:consume, %{value: 7, proof: proof})
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action()

    assert ledger_count(prefix) == 1
  end

  defp run(prefix, request_key, value) do
    Resource
    |> Ash.ActionInput.for_action(:redeem, %{value: value, request_key: request_key})
    |> Ash.ActionInput.set_tenant(prefix)
    |> Ash.run_action()
  end

  defp ledger_count(prefix) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM #{relation(prefix, "ash_onetime_generic_effect_ledger")}",
        []
      )

    count
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_onetime, key)
  defp restore_env(key, value), do: Application.put_env(:ash_onetime, key, value)
  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
