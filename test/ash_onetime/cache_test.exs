defmodule AshOnetime.CacheTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Cache, as: CacheApi
  alias AshOnetime.Cache.Entry
  alias AshOnetime.Cache.None
  alias AshOnetime.Store.{Claim, Result}
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

  describe "valid_entry? conjunct isolation and admission authority (unit)" do
    test "a fully claim-consistent entry is a hit" do
      {result, config, valid, payload} = cache_fixture()
      Cache.poison(valid)
      assert {%Result{payload: ^payload}, :hit} = CacheApi.authoritative_payload(result, config)
    end

    @tag :cache_fingerprint_conjunct_mutation
    test "an entry whose fingerprint mismatches the claim degrades to stale" do
      {result, config, valid, _payload} = cache_fixture()
      Cache.poison(%{valid | fingerprint: :crypto.hash(:sha256, "wrong-fingerprint")})
      assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)
    end

    @tag :cache_codec_conjunct_mutation
    test "an entry whose codec mismatches the claim degrades to stale" do
      {result, config, valid, _payload} = cache_fixture()
      Cache.poison(%{valid | codec: "wrong-codec"})
      assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)
    end

    @tag :cache_digest_conjunct_mutation
    test "an entry whose digest field mismatches the claim degrades to stale" do
      # The payload still rehashes to the claim digest (payload-rehash conjunct passes); only the
      # entry's own digest field is wrong, isolating the digest conjunct from the rehash.
      {result, config, valid, _payload} = cache_fixture()
      Cache.poison(%{valid | digest: :crypto.hash(:sha256, "wrong-digest")})
      assert {%Result{}, :stale} = CacheApi.authoritative_payload(result, config)
    end

    test "a live, valid cache hit is ignored when the authoritative result is not a completion" do
      {result, config, valid, _payload} = cache_fixture()
      # prime a fully valid, claim-matching hit
      Cache.poison(valid)

      # PostgreSQL is consulted first: a non-completion result (collision/rejection) never reaches
      # the cache get, so a live hit cannot turn a store rejection into an admission.
      rejection = %{result | status: :collision, payload: nil}
      assert {^rejection, :disabled} = CacheApi.authoritative_payload(rejection, config)
    end
  end

  test "None is a total no-op cache implementation" do
    key = :crypto.strong_rand_bytes(32)

    assert :miss = None.get(key)
    assert :ok = None.put(key, %Entry{}, 1)
    assert :ok = None.delete(key)
  end

  # L7: the cache key uses length-prefixed framing so a future variable-length component
  # cannot create a concatenation ambiguity. Today all components are fixed 32-byte SHA-256
  # outputs, so there is no ambiguity to remove — this is defense-in-depth, tested here with
  # synthetic variable-length inputs that WOULD collide under naive concat. The framing
  # function mirrors Cache.key/1's framing (extracted for testability; the production path
  # feeds real 32-byte Claim hashes).
  @tag cache_key_framing: true
  test "length-prefixed framing distinguishes inputs naive concat would collide" do
    # Two component lists whose naive concatenation is identical but whose components differ
    # at the boundary: ["ab", "cd"] vs ["a", "bcd"] both concat to "abcd".
    framed_a = frame(["prefix", "ab", "cd", "ef"])
    framed_b = frame(["prefix", "a", "bcd", "ef"])

    # Sanity: naive concat collides (the premise).
    naive_a = IO.iodata_to_binary(["prefix", "ab", "cd", "ef"])
    naive_b = IO.iodata_to_binary(["prefix", "a", "bcd", "ef"])
    assert naive_a == naive_b

    # The length-prefixed framing does NOT collide.
    assert :crypto.hash(:sha256, framed_a) != :crypto.hash(:sha256, framed_b)
  end

  defp frame(components),
    do:
      for(component <- components, into: "", do: <<byte_size(component)::32, component::binary>>)

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

  defp cache_fixture do
    payload = "authoritative-cache-payload"
    now = DateTime.utc_now()

    claim = %Claim{
      strategy: :idempotency,
      id: Ecto.UUID.generate(),
      operation_hash: :crypto.hash(:sha256, "operation"),
      scope_hash: :crypto.hash(:sha256, "scope"),
      key_hash: :crypto.hash(:sha256, "key"),
      fingerprint: :crypto.hash(:sha256, "fingerprint"),
      state: :complete,
      response_codec: "test-codec",
      response_digest: :crypto.hash(:sha256, payload),
      admitted_at: now,
      retain_until: DateTime.add(now, 3_600, :second),
      inserted_at: now
    }

    result = %Result{
      status: :complete,
      claim: claim,
      payload: nil,
      admission_dispatch: :sent,
      transaction: :committed
    }

    valid = %Entry{
      claim_id: claim.id,
      fingerprint: claim.fingerprint,
      codec: claim.response_codec,
      digest: claim.response_digest,
      payload: payload
    }

    {result, CacheApi.config([]), valid, payload}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ash_onetime, key)
  defp restore_env(key, value), do: Application.put_env(:ash_onetime, key, value)

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
