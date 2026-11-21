for partitioning <- [nil, 2] do
  defmodule Module.concat(
              AshOnetime.ExternalState.UpgradeRollbackTest,
              "Claims#{partitioning || "Plain"}"
            ) do
    use AshOnetime.Test.ExternalStateCase, async: false
    @moduletag hash_partitions: partitioning
    @moduletag install_in_test: true
    @moduletag :external_state_upgrade_rollback_mutation

    test "#{partitioning || "plain"}: fresh install rollback refuses an unresolved external claim",
         c do
      assert :ok = install(c)

      grant =
        Postgres.claim_committed(target(c), request!("rollback-unresolved"), lock_timeout_ms: 300)

      assert %Result{status: :admitted} = grant
      previous = Repo.put_dynamic_repo(c.owner_repo)

      result =
        try do
          Ecto.Migrator.down(Repo, 20_261_116_000_001, c.migration_module,
            prefix: c.schema,
            log: false
          )
        rescue
          error in Postgrex.Error -> {:error, error}
        after
          Repo.put_dynamic_repo(previous)
        end

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "23514"}}} = result

      assert scalar(
               c.runtime_repo,
               "SELECT count(*) FROM #{rel(c, "ash_onetime_idempotency_claims")}"
             ) == 1
    end

    test "#{partitioning || "plain"}: fresh rollback refuses a narrowed FORCE RLS view", c do
      assert :ok = install(c)

      assert %Result{status: :admitted} =
               Postgres.claim_committed(target(c), request!("forced-rollback"),
                 lock_timeout_ms: 300
               )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} ENABLE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{rel(c, "ash_onetime_idempotency_claims")} FORCE ROW LEVEL SECURITY",
        []
      )

      SQL.query!(
        c.owner_repo,
        "DROP POLICY ash_onetime_maintenance ON #{rel(c, "ash_onetime_idempotency_claims")}",
        []
      )

      previous = Repo.put_dynamic_repo(c.owner_repo)

      try do
        assert_raise Postgrex.Error, ~r/row-level security/, fn ->
          Ecto.Migrator.down(Repo, 20_261_116_000_001, c.migration_module,
            prefix: c.schema,
            log: false
          )
        end
      after
        Repo.put_dynamic_repo(previous)
      end
    end
  end
end

defmodule AshOnetime.ExternalState.UpgradeGeneratorTest do
  use ExUnit.Case, async: false
  alias AshOnetime.Test.Repo
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
  @moduletag :external_state_upgrade_generator_mutation

  setup do
    path = Path.join(System.tmp_dir!(), "ao_upgrade_generator_#{Ecto.UUID.generate()}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, path: path}
  end

  test "maintenance requires the external-state migration as well as operation hold", c do
    File.write!(Path.join(c.path, "20261116000000_add_ash_onetime_operation_hold.exs"), "")

    assert_raise Mix.Error, ~r/external.state/, fn ->
      Generator.run([
        "--repo",
        inspect(Repo),
        "--maintenance",
        "--maintenance-role",
        "maintainer",
        "--migrations-path",
        c.path,
        "--timestamp",
        "20261116000001"
      ])
    end
  end

  test "one operation-hold request generates both mandatory upgrades in order", c do
    Generator.run([
      "--repo",
      inspect(Repo),
      "--operation-hold",
      "--migrations-path",
      c.path,
      "--timestamp",
      "20261116000000"
    ])

    files = Path.wildcard(Path.join(c.path, "*.exs")) |> Enum.map(&Path.basename/1)

    assert [
             "20261116000000_add_ash_onetime_operation_hold.exs",
             "20261116000001_add_ash_onetime_external_state.exs"
           ] = files
  end
end

defmodule AshOnetime.ExternalState.OperationHoldAtomicTest do
  use ExUnit.Case, async: false
  alias AshOnetime.Test.Repo
  alias Mix.Tasks.AshOnetime.Gen.Migrations, as: Generator
  @moduletag :operation_hold_atomic_mutation

  test "operation-hold rollback restores guards inside the locked refusal block" do
    source = Generator.render_operation_hold_upgrade(Repo, [])
    [_, down] = Regex.run(~r/def down do(.*?)defp constraint_exists/s, source)

    assert Regex.match?(
             ~r/DO \$down\$.*#\{install_previous_functions\(\)\}.*DROP COLUMN hold_reference.*\$down\$/s,
             down
           )

    assert length(Regex.scan(~r/execute\(/, down)) == 1
    assert down =~ "ACCESS EXCLUSIVE"
  end
end
