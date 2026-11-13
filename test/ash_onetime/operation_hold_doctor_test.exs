defmodule AshOnetime.OperationHoldDoctorTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Transaction
  alias Mix.Tasks.AshOnetime.Doctor
  import ExUnit.CaptureIO

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  test "doctor prints held backlog and identifies counts narrowed by FORCE row security", ctx do
    for partition <- ["visible", "hidden"] do
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 assert {:execute, admission} =
                          Transaction.idempotency(Repo,
                            operation: {__MODULE__, :open},
                            prefix: ctx.prefix,
                            partition: partition,
                            scope: "scope",
                            key: "key",
                            fingerprint: hash("body"),
                            codec: "test",
                            retention_seconds: 3_600
                          )

                 Transaction.complete(admission, "response", hold: "reference")
               end)
    end

    table = ~s|"#{ctx.prefix}".ash_onetime_idempotency_claims|
    SQL.query!(Repo, "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY", [])
    SQL.query!(Repo, "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY", [])

    SQL.query!(
      Repo,
      "CREATE POLICY visible_partition ON #{table} USING (logical_partition = 'visible')",
      []
    )

    assume_non_superuser!(ctx.prefix)

    assert %{rows: [[false, false]]} =
             SQL.query!(
               Repo,
               "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user",
               []
             )

    assert {:ok, %{held_count: 1}} = Store.held_backlog(ctx.target)

    output =
      capture_io(fn ->
        Doctor.run(["--repo", inspect(Repo), "--live", "--prefix", ctx.prefix])
      end)

    assert output =~ "Held idempotency claims: 1"
    assert output =~ "oldest age"
    assert output =~ "rows visible to this role"
    assert output =~ "not an installation total"
  end

  test "doctor detects a stale operation-hold schema", ctx do
    SQL.query!(Repo, ~s|DROP INDEX "#{ctx.prefix}".ash_onetime_idempotency_claims_hold_index|, [])

    capture_io(fn ->
      assert_raise Mix.Error, ~r/check\(s\) failed/, fn ->
        Doctor.run(["--repo", inspect(Repo), "--live", "--prefix", ctx.prefix])
      end
    end)
  end

  defp assume_non_superuser!(prefix) do
    case SQL.query!(Repo, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user", []).rows do
      [[true]] ->
        role = "hold_doctor_#{System.unique_integer([:positive])}"
        SQL.query!(Repo, ~s|CREATE ROLE "#{role}" NOLOGIN NOSUPERUSER NOBYPASSRLS|, [])
        SQL.query!(Repo, ~s|GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role}"|, [])

        SQL.query!(
          Repo,
          ~s|ALTER TABLE "#{prefix}".ash_onetime_idempotency_claims OWNER TO "#{role}"|,
          []
        )

        SQL.query!(Repo, ~s|SET LOCAL ROLE "#{role}"|, [])

      [[false]] ->
        :ok
    end
  end
end
