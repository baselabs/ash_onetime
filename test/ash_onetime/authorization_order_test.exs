defmodule AshOnetime.AuthorizationOrderTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Resource.Info, as: ResourceInfo
  alias AshOnetime.Resource.Protection
  alias AshOnetime.Test.ActionExamples.{DeniedResource, Resource}

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  @tag authorization_order_mutation: true
  test "change registration performs no admission callback before Ash authorization" do
    protection = %Protection{strategy: :idempotency, action: :charge}
    changeset = Ash.Changeset.for_create(Resource, :charge, valid_input())

    Process.put({AshOnetime.Admission, :test_store}, self())
    changed = AshOnetime.Change.change(changeset, [protection: protection], %{})

    assert changed.valid?
    refute_received _message
  after
    Process.delete({AshOnetime.Admission, :test_store})
  end

  @tag reserved_mutation: true
  test "reserved verification facts reject before callbacks and SQL", %{prefix: prefix} do
    protection = ResourceInfo.protection(Resource, :charge)
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    handler = "reserved-before-sql-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, _config ->
          send(parent, {:query, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Process.put({AshOnetime.Test.ActionExamples.Verifier, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.Minter, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.TenantResolver, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.ExternalEffect, :observer}, self())

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.Verifier, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.Minter, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.TenantResolver, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.ExternalEffect, :observer})
    end)

    for reserved <- [:key, :issued_at, :expires_at, :verification_state, :algorithm],
        key <- [reserved, to_string(reserved)],
        surface <- [:params, :arguments, :attributes] do
      changeset =
        Resource
        |> Ash.Changeset.for_create(:charge, valid_input())
        |> Ash.Changeset.set_tenant(prefix)
        |> Map.update!(surface, &Map.put(&1, key, "attacker"))

      assert {:error, %AshOnetime.Error{code: :reserved_verification_input}} =
               AshOnetime.Admission.reserve(changeset, protection, %{})
    end

    nonce = ResourceInfo.protection(Resource, :consume)

    for reserved <- [:key, :issued_at, :expires_at, :verification_state, :algorithm],
        key <- [reserved, to_string(reserved)] do
      input =
        Resource
        |> Ash.ActionInput.for_action(:consume, %{value: 1, proof: "reserved-proof"})
        |> Ash.ActionInput.set_tenant(prefix)
        |> Map.update!(:arguments, &Map.put(&1, key, "attacker"))

      assert {:error, %AshOnetime.Error{code: :reserved_verification_input}} =
               AshOnetime.Admission.reserve(input, nonce, %{})
    end

    external = ResourceInfo.protection(Resource, :external_redeem)

    external_input =
      Resource
      |> Ash.ActionInput.for_action(:external_redeem, %{
        value: 1,
        request_key: "reserved-external",
        proof: "reserved-external-proof"
      })
      |> Ash.ActionInput.set_tenant(prefix)
      |> Map.update!(:arguments, &Map.put(&1, :verification_state, "attacker"))

    assert {:error, %AshOnetime.Error{code: :reserved_verification_input}} =
             AshOnetime.Admission.reserve(external_input, external, %{})

    refute_receive {:query, _sql}
    refute_receive {:verifier, _token}
    refute_receive :minter
    refute_receive :tenant_resolver
    refute_receive {:external, _operation}
  end

  test "denied authorization reaches no claim or business SQL", %{prefix: prefix} do
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    handler = "denied-before-sql-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, _config ->
          send(parent, {:query, metadata.query})
        end,
        nil
      )

    assert {:error, _error} =
             DeniedResource
             |> Ash.Changeset.for_create(:attempt, %{amount: 10, request_key: "denied"})
             |> Ash.Changeset.set_tenant(prefix)
             |> Ash.create(authorize?: true)

    :ok = :telemetry.detach(handler)
    refute_receive {:query, _sql}
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
  end

  test "denied generic authorization reaches no claim executor or notifier", %{prefix: prefix} do
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    handler = "denied-generic-before-sql-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, metadata, _config ->
          query = String.downcase(metadata.query)

          if String.contains?(query, [
               "ash_onetime_idempotency_claims",
               "ash_onetime_nonce_claims",
               "ash_onetime_response_payloads",
               "ash_onetime_generic_effect_ledger"
             ]) do
            send(parent, {:denied_generic_protected_query, metadata.query})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.Notifier, :observer}, self())
    Process.put({AshOnetime.Test.ActionExamples.GenericRun, :notify?}, true)

    on_exit(fn ->
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.Notifier, :observer})
      Process.delete({AshOnetime.Test.ActionExamples.GenericRun, :notify?})
    end)

    assert {:error, _error} =
             DeniedResource
             |> Ash.ActionInput.for_action(:denied_redeem, %{
               value: 10,
               request_key: "denied-generic"
             })
             |> Ash.ActionInput.set_tenant(prefix)
             |> Ash.run_action(authorize?: true)

    :ok = :telemetry.detach(handler)
    refute_receive {:denied_generic_protected_query, _sql}
    refute_receive {:generic_run, _arguments}
    refute_receive {:generic_notification, _value}
    assert table_count(prefix, "ash_onetime_idempotency_claims") == 0
  end

  defp valid_input do
    %{
      account_id: Ecto.UUID.generate(),
      amount: 10,
      request_key: "request-1",
      natural_key: "natural-1",
      external_key: "external-1"
    }
  end

  defp table_count(prefix, table) do
    %{rows: [[count]]} =
      SQL.query!(Repo, "SELECT count(*) FROM \"#{prefix}\".\"#{table}\"", [])

    count
  end
end
