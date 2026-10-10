defmodule AshOnetime.NonceRetentionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.{Error, Transaction, Verified, Window}

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "nonce guide transaction example executes and reads the stored deadline", %{prefix: prefix} do
    path = "documentation/one-time-nonces.md"

    [_, source] =
      Regex.run(
        ~r/<!-- nonce-retention-transaction:start -->\s*```elixir\s*(.*?)\s*```/s,
        File.read!(path)
      )

    issued = Clock.now()
    {:ok, fact} = Verified.new(key: "guide-nonce", issued_at: issued, verifier_id: "guide")

    bindings = [
      repo: Repo,
      prefix: prefix,
      tenant_id: "tenant",
      principal_id: "principal",
      nonce: "guide-nonce",
      verified_fact: fact,
      clock: Clock
    ]

    assert {:ok, {deadline, _bindings}} =
             Repo.transaction(fn -> Code.eval_string(source, bindings, file: path) end)

    assert deadline == stored_deadline(prefix)
    assert deadline == Window.cleanup_after(issued, 664, 0)
  end

  test "composite facts retain through the latest sibling deadline with skew", %{prefix: prefix} do
    now = Clock.now()

    {:ok, older} =
      Verified.new(
        key: "composite",
        issued_at: DateTime.add(now, -100, :second),
        expires_at: DateTime.add(now, 10, :second),
        verifier_id: "older"
      )

    {:ok, newer} = Verified.new(key: "composite", issued_at: now, verifier_id: "newer")

    options =
      options(prefix, "composite", now) |> Keyword.merge(verified: [older, newer], clock_skew: 5)

    assert {:ok, :ok} = spend(options)
    assert stored_deadline(prefix) == Window.cleanup_after(now, 664, 5)
    Clock.freeze(DateTime.add(now, 400, :second))
    assert {:ok, {:error, %Error{code: :nonce_already_used}}} = spend(options)
  end

  test "omitted retention preserves legacy oversized-window rejection", %{prefix: prefix} do
    options =
      options(prefix, "legacy-invalid", Clock.now())
      |> Keyword.delete(:retain_for)
      |> Keyword.put(:max_age, 2_147_483_648)

    assert {:ok, {:error, %Error{code: :invalid_nonce_window}}} = spend(options)
  end

  @tag retention_acceptance_mutation: true
  test "long retention never widens acceptance", %{prefix: prefix} do
    options = options(prefix, "too-old", Clock.now())
    Clock.freeze(DateTime.add(Clock.now(), 301, :second))

    assert {:ok, {:error, %Error{code: :invalid_nonce_window}}} = spend(options)
    assert count(prefix) == 0
  end

  @tag retention_duration_mutation: true
  @tag retention_replay_mutation: true
  test "late replay remains a collision and cleanup preserves the stored deadline", %{
    prefix: prefix,
    target: target
  } do
    # Anchor to PostgreSQL's transaction clock, then move only the injected application clock.
    %{rows: [[now]]} = SQL.query!(Repo, "SELECT transaction_timestamp()", [])
    issued = DateTime.add(now, -400, :second)
    Clock.freeze(issued)
    options = options(prefix, "late-replay", issued)
    assert {:ok, :ok} = spend(options)
    # Age the database admission floor too: legacy retention is now past,
    # while the extended retention deadline remains in the future.
    age_row(prefix, 200)
    issued = DateTime.add(issued, -200, :second)
    options = options(prefix, "late-replay", issued)
    Clock.freeze(now)

    assert {:ok, %{nonce: 0}} = Store.cleanup(target, 100)
    assert count(prefix) == 1
    assert {:ok, {:error, %Error{code: :nonce_already_used}}} = spend(options)
    assert {:ok, deadline} = Transaction.nonce_retention_deadline(Repo, locator(options))
    assert deadline == Window.cleanup_after(issued, 664, 0)
    assert stored_deadline(prefix) == deadline
  end

  test "cleanup removes a claim strictly after its computed retention deadline", %{
    prefix: prefix,
    target: target
  } do
    %{rows: [[now]]} = SQL.query!(Repo, "SELECT transaction_timestamp()", [])
    Clock.freeze(now)
    options = options(prefix, "cleanup-expired", now)
    assert {:ok, :ok} = spend(options)
    assert stored_deadline(prefix) == Window.cleanup_after(now, 664, 0)

    # PostgreSQL owns cleanup time. Age this real row coherently instead of sleeping
    # or replacing the cleanup predicate; its original deadline formula is preserved.
    elapsed = 665 + Window.cleanup_skew_margin_seconds()

    SQL.query!(
      Repo,
      """
      UPDATE "#{prefix}".ash_onetime_nonce_claims
      SET issued_at = issued_at - ($1::bigint * interval '1 second'),
          admitted_at = admitted_at - ($1::bigint * interval '1 second'),
          inserted_at = inserted_at - ($1::bigint * interval '1 second'),
          retain_until = retain_until - ($1::bigint * interval '1 second')
      """,
      [elapsed]
    )

    issued = DateTime.add(now, -elapsed, :second)
    assert stored_deadline(prefix) == Window.cleanup_after(issued, 664, 0)

    Clock.freeze(now)
    assert {:ok, %{nonce: 1}} = Store.cleanup(target, 100)
    assert count(prefix) == 0
    assert :not_found = Transaction.nonce_retention_deadline(Repo, locator(options))

    assert {:ok, {:error, %Error{code: :invalid_nonce_window}}} =
             spend(options(prefix, "cleanup-expired", issued))

    assert count(prefix) == 0
  end

  @tag retention_legacy_mutation: true
  test "omitting retain_for preserves the exact old stored deadline", %{prefix: prefix} do
    issued = Clock.now()

    for skew <- [0, 7], composite? <- [false, true] do
      key = "omitted-#{skew}-#{composite?}"
      omitted = options(prefix, key, issued) |> Keyword.delete(:retain_for)
      omitted = Keyword.put(omitted, :clock_skew, skew)

      omitted =
        if composite? do
          {:ok, older} =
            Verified.new(
              key: key,
              issued_at: DateTime.add(issued, -100, :second),
              expires_at: DateTime.add(issued, 10, :second),
              verifier_id: "older"
            )

          Keyword.update!(omitted, :verified, &[older | &1])
        else
          omitted
        end

      explicit = omitted |> Keyword.put(:retain_for, 300) |> Keyword.put(:partition, "explicit")
      assert {:ok, :ok} = spend(omitted)
      assert {:ok, legacy} = Transaction.nonce_retention_deadline(Repo, locator(omitted))

      assert legacy ==
               DateTime.add(issued, 300 + skew + Window.cleanup_skew_margin_seconds(), :second)

      assert {:ok, :ok} = spend(explicit)
      assert {:ok, ^legacy} = Transaction.nonce_retention_deadline(Repo, locator(explicit))
      Clock.freeze(DateTime.add(issued, 301 + skew, :second))
      assert {:ok, {:error, %Error{code: :invalid_nonce_window}}} = spend(omitted)
      Clock.freeze(issued)
    end
  end

  @tag retention_upper_bound_mutation: true
  test "the positive retention plus skew upper bound stores and reads its deadline", %{
    prefix: prefix
  } do
    issued = Clock.now()

    options =
      options(prefix, "upper-bound", issued)
      |> Keyword.merge(retain_for: 2_147_483_640, clock_skew: 7)

    assert {:ok, :ok} = spend(options)
    assert {:ok, deadline} = Transaction.nonce_retention_deadline(Repo, locator(options))

    assert deadline ==
             DateTime.add(issued, 2_147_483_647 + Window.cleanup_skew_margin_seconds(), :second)

    assert deadline == stored_deadline(prefix)
  end

  @tag retention_classification_mutation: true
  test "late replay classification follows the stored deadline including its endpoint", %{
    prefix: prefix
  } do
    issued = Clock.now()
    options = options(prefix, "stored-boundary", issued)
    assert {:ok, :ok} = spend(options)
    assert {:ok, deadline} = Transaction.nonce_retention_deadline(Repo, locator(options))

    # A caller's new, longer policy cannot extend this already stored deadline.
    for retention <- [300, 10_000],
        instant <- [DateTime.add(deadline, -1, :microsecond), deadline] do
      Clock.freeze(instant)
      replay = Keyword.put(options, :retain_for, retention)
      assert {:ok, {:error, %Error{code: :nonce_already_used}}} = spend(replay)
    end

    Clock.freeze(DateTime.add(deadline, 1, :microsecond))
    assert count(prefix) == 1
    replay = Keyword.put(options, :retain_for, 10_000)
    assert {:ok, {:error, %Error{code: :invalid_nonce_window}}} = spend(replay)
    assert {:ok, ^deadline} = Transaction.nonce_retention_deadline(Repo, locator(options))
  end

  @tag retention_read_savepoint_mutation: true
  test "a deadline query failure preserves caller writes and transaction usability", %{
    prefix: prefix
  } do
    options = options(prefix, "savepoint", Clock.now())

    assert {:ok, :usable} =
             Repo.transaction(fn ->
               assert :ok = Transaction.nonce(Repo, options)
               missing = Keyword.put(locator(options), :prefix, "uninstalled_retention_store")

               assert {:error, %Error{code: :store_invariant}} =
                        Transaction.nonce_retention_deadline(Repo, missing)

               assert %{rows: [[1]]} = SQL.query!(Repo, "SELECT 1", [])

               assert {:ok, _deadline} =
                        Transaction.nonce_retention_deadline(Repo, locator(options))

               :usable
             end)

    assert count(prefix) == 1
  end

  @tag retention_read_dispatch_mutation: true
  test "an unexpected deadline row has no admission dispatch", %{prefix: prefix, target: target} do
    request = nonce_request("invalid-deadline")

    assert {:ok, %Result{status: :admitted}} =
             Repo.transaction(fn -> Store.claim(target, request) end)

    # Exercise the real decoder against a damaged installation.
    SQL.query!(
      Repo,
      ~s(ALTER TABLE "#{prefix}".ash_onetime_nonce_claims ALTER COLUMN retain_until DROP NOT NULL),
      []
    )

    SQL.query!(Repo, ~s(UPDATE "#{prefix}".ash_onetime_nonce_claims SET retain_until = NULL), [])

    assert %Result{reason: :store_invariant, admission_dispatch: :not_started} =
             Postgres.nonce_retention_deadline(
               target,
               request.operation_hash,
               request.scope_hash,
               request.key_hash
             )
  end

  @tag unboxed: true
  @tag retention_read_lock_mutation: true
  test "late replay classification does not wait for a row lock", %{prefix: prefix} do
    repo = start_unboxed_repo!()
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      issued = Clock.now()
      options = options(prefix, "unlocked-classification", issued)
      assert {:ok, :ok} = spend(options)

      assert {:ok, {:ok, {:error, %Error{code: :nonce_already_used}}}} =
               Repo.transaction(fn ->
                 %{rows: [[holder]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])

                 assert %{num_rows: 1} =
                          SQL.query!(
                            repo,
                            ~s(SELECT id FROM "#{prefix}".ash_onetime_nonce_claims FOR UPDATE),
                            []
                          )

                 Task.async(fn ->
                   Repo.put_dynamic_repo(repo)
                   Clock.freeze(DateTime.add(issued, 400, :second))

                   Repo.transaction(fn ->
                     %{rows: [[reader]]} = SQL.query!(repo, "SELECT pg_backend_pid()", [])
                     refute reader == holder
                     SQL.query!(repo, "SET LOCAL lock_timeout = '100ms'", [])
                     Transaction.nonce(Repo, options)
                   end)
                 end)
                 |> Task.await(5_000)
               end)
    after
      age_row(prefix, 1_000)
      SQL.query!(Repo, ~s(DELETE FROM "#{prefix}".ash_onetime_nonce_claims), [])
      Repo.put_dynamic_repo(previous)
    end
  end

  test "invalid retention is refused by both runtime construction paths", %{prefix: prefix} do
    for retain_for <- [299, -1, nil, 664.0, "664", 2_147_483_648] do
      options = options(prefix, "invalid", Clock.now()) |> Keyword.put(:retain_for, retain_for)
      assert {:ok, {:error, %Error{code: :invalid_request}}} = spend(options)
      assert {:error, :invalid_request} = Claim.nonce(claim_attributes(options))
    end

    options =
      options(prefix, "sum-overflow", Clock.now())
      |> Keyword.merge(retain_for: 2_147_483_647, clock_skew: 1)

    assert {:ok, {:error, %Error{code: :invalid_request}}} = spend(options)
    assert {:error, :invalid_request} = Claim.nonce(claim_attributes(options))
    assert count(prefix) == 0
  end

  test "deadline read uses stored authority and isolates every locator component", %{
    prefix: prefix
  } do
    options = options(prefix, "read-deadline", Clock.now())
    assert {:ok, :ok} = spend(options)
    locator = locator(options)
    assert {:ok, deadline} = Transaction.nonce_retention_deadline(Repo, locator)
    assert deadline == stored_deadline(prefix)

    for {key, value} <- [
          partition: "other-tenant",
          scope: "other-principal",
          key: "other-nonce",
          operation: {__MODULE__, :other}
        ] do
      assert :not_found =
               Transaction.nonce_retention_deadline(Repo, Keyword.put(locator, key, value))
    end

    for invalid <- [
          locator ++ [key: "duplicate"],
          Keyword.put(locator, :retain_for, 999),
          Keyword.put(locator, :prefix, ""),
          Keyword.delete(locator, :partition)
        ] do
      assert {:error, %Error{code: :invalid_request}} =
               Transaction.nonce_retention_deadline(Repo, invalid)
    end
  end

  test "the store validates retention even for a directly altered request", %{
    target: target,
    prefix: prefix
  } do
    options = options(prefix, "altered", Clock.now())
    assert {:ok, request} = Claim.nonce(claim_attributes(options))

    for retain_for <- [299, -1, 2_147_483_648] do
      altered = Map.put(request, :retain_for, retain_for)

      assert {:ok, %Result{status: :failure, reason: :invalid_request}} =
               Repo.transaction(fn -> Store.claim(target, altered) end)
    end
  end

  defp age_row(prefix, elapsed) do
    SQL.query!(
      Repo,
      """
      UPDATE "#{prefix}".ash_onetime_nonce_claims
      SET issued_at = issued_at - ($1::bigint * interval '1 second'),
          admitted_at = admitted_at - ($1::bigint * interval '1 second'),
          inserted_at = inserted_at - ($1::bigint * interval '1 second'),
          retain_until = retain_until - ($1::bigint * interval '1 second')
      """,
      [elapsed]
    )
  end

  defp options(prefix, key, issued) do
    {:ok, verified} = Verified.new(key: key, issued_at: issued, verifier_id: "retention-test")

    [
      operation: {__MODULE__, :nonce},
      partition: "tenant",
      prefix: prefix,
      scope: "principal",
      key: key,
      verified: [verified],
      max_age: 300,
      retain_for: 664,
      clock_skew: 0,
      clock: Clock
    ]
  end

  defp claim_attributes(options) do
    Keyword.take(options, [:verified, :max_age, :retain_for, :clock_skew, :clock]) ++
      [operation_hash: hash("operation"), scope_hash: hash("scope"), key_hash: hash("key")]
  end

  defp locator(options),
    do: Keyword.take(options, [:operation, :partition, :prefix, :scope, :key])

  defp spend(options), do: Repo.transaction(fn -> Transaction.nonce(Repo, options) end)

  defp count(prefix) do
    %{rows: [[count]]} =
      SQL.query!(Repo, ~s|SELECT count(*) FROM "#{prefix}".ash_onetime_nonce_claims|, [])

    count
  end

  defp stored_deadline(prefix) do
    %{rows: [[deadline]]} =
      SQL.query!(Repo, ~s(SELECT retain_until FROM "#{prefix}".ash_onetime_nonce_claims), [])

    deadline
  end
end
