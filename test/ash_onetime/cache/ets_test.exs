defmodule AshOnetime.Cache.EtsTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Cache.Entry
  alias AshOnetime.Cache.Ets

  # The ETS adapter owns a named table under AshOnetime.Cache.Ets; start the owning GenServer
  # per test and clear between cases. async: false because the named table is VM-global.
  setup do
    start_supervised!({Ets, max_entries: 3})
    Ets.clear()
    :ok
  end

  describe "get/put/delete" do
    test "a stored entry is returned by get and removed by delete" do
      entry = %Entry{claim_id: Ecto.UUID.generate(), payload: "payload-1"}
      assert :ok = Ets.put("key-1", entry, 60)

      assert {:ok, ^entry} = Ets.get("key-1")

      assert :ok = Ets.delete("key-1")
      assert :miss = Ets.get("key-1")
    end

    test "a miss returns :miss without error" do
      assert :miss = Ets.get("absent")
    end

    test "put rejects a non-positive ttl" do
      entry = %Entry{claim_id: Ecto.UUID.generate(), payload: "payload"}

      assert {:error, :invalid_entry} = Ets.put("key", entry, 0)
      assert {:error, :invalid_entry} = Ets.put("key", entry, -1)
    end
  end

  describe "TTL expiry" do
    # :ets has no native TTL; the adapter stores a monotonic deadline and get/1 rejects (and
    # lazily deletes) expired entries. A 1-second TTL plus a short sleep is the proof.
    test "an entry past its TTL is rejected and lazily deleted" do
      entry = %Entry{claim_id: Ecto.UUID.generate(), payload: "expiring"}
      assert :ok = Ets.put("ttl-key", entry, 1)

      # Still fresh immediately.
      assert {:ok, ^entry} = Ets.get("ttl-key")

      Process.sleep(1_100)

      # Past the deadline: rejected and deleted.
      assert :miss = Ets.get("ttl-key")
      assert :miss = Ets.get("ttl-key")
    end
  end

  describe "bounded eviction" do
    # max_entries is 3 (set in setup). The 4th put evicts the oldest-by-deadline entry.
    test "put evicts an entry when the cap is reached and keeps the cap bounded" do
      e1 = %Entry{claim_id: Ecto.UUID.generate(), payload: "1"}
      e2 = %Entry{claim_id: Ecto.UUID.generate(), payload: "2"}
      e3 = %Entry{claim_id: Ecto.UUID.generate(), payload: "3"}

      assert :ok = Ets.put("k1", e1, 60)
      assert :ok = Ets.put("k2", e2, 60)
      assert :ok = Ets.put("k3", e3, 60)

      e4 = %Entry{claim_id: Ecto.UUID.generate(), payload: "4"}
      assert :ok = Ets.put("k4", e4, 60)

      # Exactly one of the original three was evicted (the oldest-by-deadline; on an equal-TTL
      # tie the choice is unspecified, so the contract is "one evicted, the cap holds").
      remaining = for k <- ["k1", "k2", "k3"], match?({:ok, _}, Ets.get(k)), do: k
      assert length(remaining) == 2

      # k4 (just inserted) survives, and the cap is not exceeded.
      assert {:ok, ^e4} = Ets.get("k4")
      assert Ets.max_entries() == 3
    end

    test "eviction picks the earliest deadline, not the earliest insert" do
      # k1 has a LONGER ttl than k2, so when the cap is reached k2 (earlier deadline) is evicted.
      e1 = %Entry{claim_id: Ecto.UUID.generate(), payload: "1"}
      e2 = %Entry{claim_id: Ecto.UUID.generate(), payload: "2"}
      e3 = %Entry{claim_id: Ecto.UUID.generate(), payload: "3"}

      assert :ok = Ets.put("k1", e1, 600)
      assert :ok = Ets.put("k2", e2, 60)
      assert :ok = Ets.put("k3", e3, 600)

      e4 = %Entry{claim_id: Ecto.UUID.generate(), payload: "4"}
      assert :ok = Ets.put("k4", e4, 600)

      # k2 had the earliest deadline (60s vs 600s) so it is evicted; k1 survives.
      assert {:ok, ^e1} = Ets.get("k1")
      assert :miss = Ets.get("k2")
      assert {:ok, ^e3} = Ets.get("k3")
      assert {:ok, ^e4} = Ets.get("k4")
    end
  end

  describe "clear" do
    test "clear drops every entry but retains the config" do
      e = %Entry{claim_id: Ecto.UUID.generate(), payload: "x"}
      assert :ok = Ets.put("k", e, 60)
      assert {:ok, ^e} = Ets.get("k")

      assert :ok = Ets.clear()
      assert :miss = Ets.get("k")

      # The config (max_entries) survives clear.
      assert Ets.max_entries() == 3

      # The cache is still usable after clear.
      assert :ok = Ets.put("k2", e, 60)
      assert {:ok, ^e} = Ets.get("k2")
    end
  end
end
