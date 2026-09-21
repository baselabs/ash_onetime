defmodule AshOnetime.VerifiedTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Test.VerifiedMinter
  alias AshOnetime.Verified

  @issued_at ~U[2026-09-20 12:00:00Z]
  @verifier_id "report-envelope-verifier"

  test "mints verified facts and defaults expires_at to nil" do
    assert {:ok, %Verified{} = verified} =
             Verified.new(key: "nonce-1", issued_at: @issued_at, verifier_id: @verifier_id)

    assert %Verified{
             key: "nonce-1",
             issued_at: @issued_at,
             expires_at: nil,
             verifier_id: @verifier_id
           } =
             verified
  end

  test "accepts an expires_at at or after issued_at, and an explicit nil" do
    assert {:ok, %Verified{expires_at: @issued_at}} =
             Verified.new(
               key: "nonce-1",
               issued_at: @issued_at,
               expires_at: @issued_at,
               verifier_id: @verifier_id
             )

    assert {:ok, %Verified{expires_at: expires_at}} =
             Verified.new(
               key: "nonce-1",
               issued_at: @issued_at,
               expires_at: ~U[2026-09-20 12:01:00Z],
               verifier_id: @verifier_id
             )

    assert expires_at == ~U[2026-09-20 12:01:00Z]

    assert {:ok, %Verified{expires_at: nil}} =
             Verified.new(
               key: "nonce-1",
               issued_at: @issued_at,
               expires_at: nil,
               verifier_id: @verifier_id
             )
  end

  @tag :verified_shape_rejection_mutation
  test "rejects input that is not a keyword list" do
    assert {:error, reason} = Verified.new(%{key: "nonce-1"})
    assert reason =~ "keyword list"

    assert {:error, reason} = Verified.new(:key)
    assert reason =~ "keyword list"

    assert {:error, reason} = Verified.new("key")
    assert reason =~ "keyword list"

    assert {:error, reason} = Verified.new([{:key, "nonce-1", :extra}])
    assert reason =~ "keyword list"
  end

  @tag :verified_unknown_keys_mutation
  test "rejects unknown keys" do
    assert {:error, reason} =
             Verified.new(
               key: "nonce-1",
               issued_at: @issued_at,
               verifier_id: @verifier_id,
               verifier: @verifier_id
             )

    assert reason =~ "accept only"
  end

  @tag :verified_duplicate_keys_mutation
  test "rejects duplicate keys" do
    assert {:error, reason} =
             Verified.new(
               key: "nonce-1",
               key: "nonce-2",
               issued_at: @issued_at,
               verifier_id: @verifier_id
             )

    assert reason =~ "unique"
  end

  @tag :verified_missing_required_mutation
  test "rejects a missing required key" do
    for missing <- [:key, :issued_at, :verifier_id] do
      fields =
        [key: "nonce-1", issued_at: @issued_at, verifier_id: @verifier_id]
        |> Keyword.delete(missing)

      expected = "verified facts require #{inspect([missing])}"
      assert {:error, ^expected} = Verified.new(fields)
    end
  end

  @tag :verified_key_validation_mutation
  test "rejects a key that is not a non-empty binary" do
    for key <- [:nonce, "", 123, nil] do
      assert {:error, "key must be a non-empty binary"} =
               Verified.new(key: key, issued_at: @issued_at, verifier_id: @verifier_id)
    end
  end

  @tag :verified_issued_at_validation_mutation
  test "rejects an issued_at that is not a DateTime" do
    for issued_at <- [~N[2026-09-20 12:00:00], ~D[2026-09-20], 1_761_000_000, "2026-09-20"] do
      assert {:error, "issued_at must be a DateTime"} =
               Verified.new(key: "nonce-1", issued_at: issued_at, verifier_id: @verifier_id)
    end
  end

  @tag :verified_expires_at_validation_mutation
  test "rejects an expires_at that is neither nil nor a DateTime" do
    for expires_at <- [~N[2026-09-20 13:00:00], 1_761_000_000, "2026-09-20"] do
      assert {:error, "expires_at must be a DateTime or nil"} =
               Verified.new(
                 key: "nonce-1",
                 issued_at: @issued_at,
                 expires_at: expires_at,
                 verifier_id: @verifier_id
               )
    end
  end

  test "rejects forged datetimes and never raises" do
    forged_issued_at = %DateTime{
      year: 2026,
      month: 13,
      day: 1,
      zone_abbr: "UTC",
      hour: 0,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      utc_offset: 0,
      std_offset: 0,
      time_zone: "Etc/UTC"
    }

    forged_expires_at = %{forged_issued_at | day: 2}

    assert {:error, "issued_at must be a DateTime"} =
             Verified.new(key: "nonce-1", issued_at: forged_issued_at, verifier_id: @verifier_id)

    assert {:error, "expires_at must be a DateTime or nil"} =
             Verified.new(
               key: "nonce-1",
               issued_at: @issued_at,
               expires_at: forged_expires_at,
               verifier_id: @verifier_id
             )
  end

  @tag :verified_expiry_order_mutation
  test "rejects an expires_at before issued_at" do
    assert {:error, reason} =
             Verified.new(
               key: "nonce-1",
               issued_at: @issued_at,
               expires_at: ~U[2026-09-20 11:59:59Z],
               verifier_id: @verifier_id
             )

    assert reason =~ "before"
  end

  @tag :verified_verifier_id_bound_mutation
  test "rejects a verifier_id that is not a non-empty binary within the 128-byte bound" do
    for verifier_id <- [:verifier, "", 123, String.duplicate("v", 129)] do
      assert {:error, reason} =
               Verified.new(key: "nonce-1", issued_at: @issued_at, verifier_id: verifier_id)

      assert reason =~ "verifier_id"
    end

    at_bound = String.duplicate("v", 128)

    assert {:ok, %Verified{verifier_id: ^at_bound}} =
             Verified.new(key: "nonce-1", issued_at: @issued_at, verifier_id: at_bound)
  end

  test "mints a key of any length (the key bound is per-action, not the type's)" do
    large_key = String.duplicate("k", 10_000)

    assert {:ok, %Verified{key: ^large_key}} =
             Verified.new(key: large_key, issued_at: @issued_at, verifier_id: @verifier_id)
  end

  test "the verifier-id byte bound agrees across every site that enforces it" do
    assert File.read!("lib/ash_onetime/verified.ex") =~ "@max_verifier_id_bytes 128"
    assert File.read!("lib/ash_onetime/store/claim.ex") =~ "@max_verifier_id_bytes 128"
    assert File.read!("lib/ash_onetime/admission.ex") =~ "byte_size(verifier_id) <= 128"

    assert File.read!("lib/ash_onetime/admission.ex") =~
             "bounded_binary(verified.verifier_id, 128)"
  end

  test "a consumer-shaped module mints through new/1 under an opaque spec" do
    assert {:ok, [%Verified{} = verified]} =
             VerifiedMinter.mint_facts("nonce-1", @issued_at, @verifier_id)

    assert %Verified{key: "nonce-1", expires_at: nil} = verified

    assert {:error, "key must be a non-empty binary"} =
             VerifiedMinter.mint_facts("", @issued_at, @verifier_id)
  end
end
