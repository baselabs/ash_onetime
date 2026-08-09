defmodule AshOnetime.TenantPrefixTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Store.Postgres
  alias AshOnetime.Test.ActionExamples.Resource
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    first = install_store!()
    second_prefix = "ash_onetime_test_#{Ecto.UUID.generate() |> String.replace("-", "")}"
    second_version = first.version + 1

    Sandbox.mode(Repo, :auto)

    try do
      SQL.query!(Repo, ~s(CREATE SCHEMA "#{second_prefix}"), [])

      :ok =
        Ecto.Migrator.up(Repo, second_version, first.module, prefix: second_prefix, log: false)
    after
      Sandbox.mode(Repo, :manual)
    end

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      try do
        _result =
          Ecto.Migrator.down(Repo, second_version, first.module,
            prefix: second_prefix,
            log: false
          )

        SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "#{second_prefix}" CASCADE), [])
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    {:ok, prefix: first.schema, second_prefix: second_prefix}
  end

  setup %{prefix: prefix, second_prefix: second_prefix} do
    for tenant <- [prefix, second_prefix] do
      SQL.query!(
        Repo,
        """
        CREATE TABLE #{relation(tenant, "ash_onetime_action_examples")} (
          id uuid PRIMARY KEY,
          account_id uuid NOT NULL,
          amount bigint NOT NULL
        )
        """,
        []
      )
    end

    :ok
  end

  test "context resources require and preserve the Ash-resolved PostgreSQL prefix" do
    assert %AshOnetime.Store.Result{reason: :missing_prefix} = Postgres.target(Resource)

    assert {:ok, %Postgres.Target{repo_module: AshOnetime.Test.Repo, prefix: "tenant_a"}} =
             Postgres.target(Resource, tenant: "tenant_a")
  end

  @tag prefix_routing_mutation: true
  test "the same complete key is isolated across two tenant prefixes", %{
    prefix: prefix,
    second_prefix: second_prefix
  } do
    account_id = Ecto.UUID.generate()

    input = %{
      account_id: account_id,
      amount: 10,
      request_key: "same-key",
      natural_key: "same-natural",
      external_key: "same-external"
    }

    assert {:ok, first} = create_in(prefix, input)
    assert {:ok, second} = create_in(second_prefix, input)
    refute first.id == second.id

    for tenant <- [prefix, second_prefix] do
      assert table_count(tenant, "ash_onetime_action_examples") == 1
      assert table_count(tenant, "ash_onetime_idempotency_claims") == 1
      assert table_count(tenant, "ash_onetime_response_payloads") == 1
    end
  end

  test "a replayed idempotent result preserves the fresh result's tenant", %{prefix: prefix} do
    input = %{
      account_id: Ecto.UUID.generate(),
      amount: 10,
      request_key: "fidelity-key",
      natural_key: "fidelity-natural",
      external_key: "fidelity-external"
    }

    assert {:ok, fresh} = create_in(prefix, input)
    assert {:ok, replayed} = create_in(prefix, input)

    assert replayed.id == fresh.id
    assert replayed.__meta__.prefix == fresh.__meta__.prefix
    assert fresh.__metadata__.tenant == prefix
    assert replayed.__metadata__.tenant == prefix
    # The replay signal (replayed: true vs false) is intentionally fresh/replay-specific,
    # so compare the tenant only — this test asserts tenant isolation, not full-metadata
    # equality.
    assert replayed.__metadata__.tenant == fresh.__metadata__.tenant
  end

  defp create_in(prefix, input) do
    Resource
    |> Ash.Changeset.for_create(:charge, input)
    |> Ash.Changeset.set_tenant(prefix)
    |> Ash.create()
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM #{relation(prefix, table)}", [])
    count
  end

  defp relation(prefix, table), do: ~s("#{prefix}"."#{table}")
end
