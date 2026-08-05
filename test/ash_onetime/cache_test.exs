defmodule AshOnetime.CacheTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Cache.Entry
  alias AshOnetime.Cache.None
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.Cache

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
      Cache.reset()
    end)

    :ok
  end

  test "poisoned and stale cache hits cannot admit an effect or replace authoritative replay", %{
    prefix: prefix
  } do
    key = "poisoned-#{System.unique_integer([:positive])}"
    assert {:ok, 41} = run_generic(prefix, :redeem, %{value: 41, request_key: key})
    assert [_stored] = Cache.entries()

    Cache.poison(%Entry{
      claim_id: Ecto.UUID.generate(),
      fingerprint: :crypto.hash(:sha256, "wrong-fingerprint"),
      codec: "poisoned-codec",
      digest: :crypto.hash(:sha256, "poisoned"),
      payload: "poisoned"
    })

    assert {:ok, 41} = run_generic(prefix, :redeem, %{value: 41, request_key: key})
    assert ledger_count(prefix) == 1

    [{{:entry, _cache_key}, %Entry{} = authoritative, _ttl}] = Cache.entries()
    Cache.poison(%{authoritative | payload: "stale-payload"})

    assert {:ok, 41} = run_generic(prefix, :redeem, %{value: 41, request_key: key})
    assert ledger_count(prefix) == 1
  end

  test "circuit-open timeout and corrupt cache values degrade to authoritative replay", %{
    prefix: prefix
  } do
    for mode <- [:circuit_open, :timeout, :corrupt] do
      key = "cache-#{mode}-#{System.unique_integer([:positive])}"
      Cache.mode(:normal)
      assert {:ok, 17} = run_generic(prefix, :redeem, %{value: 17, request_key: key})

      Cache.mode(mode)
      assert {:ok, 17} = run_generic(prefix, :redeem, %{value: 17, request_key: key})
    end

    assert ledger_count(prefix) == 3
  end

  test "a cache never rejects or admits a nonce", %{prefix: prefix} do
    Cache.mode(:circuit_open)
    proof = "nonce-cache-#{System.unique_integer([:positive])}"

    assert {:ok, 9} = run_generic(prefix, :consume, %{value: 9, proof: proof})
    assert {:error, _error} = run_generic(prefix, :consume, %{value: 9, proof: proof})
    assert ledger_count(prefix) == 1
  end

  test "None is a total no-op cache implementation" do
    key = :crypto.strong_rand_bytes(32)

    assert :miss = None.get(key)
    assert :ok = None.put(key, %Entry{}, 1)
    assert :ok = None.delete(key)
  end

  defp run_generic(prefix, action, arguments) do
    Resource
    |> Ash.ActionInput.for_action(action, arguments)
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
