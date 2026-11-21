defmodule AshOnetime.Store.ColumnNullabilityTest do
  use AshOnetime.Test.ExternalStateCase, async: false

  for {operation, column, original_not_null, restoration} <- [
        {"DROP", "verifier_id", true, "SET"},
        {"SET", "expires_at", false, "DROP"}
      ] do
    @operation operation
    @column column
    @original_not_null original_not_null
    @restoration restoration
    @tag :maintenance_shape_not_null_mutation
    test "maintenance refuses #{@operation} NOT NULL drift and recovers after restoration", c do
      table = rel(c, "ash_onetime_nonce_claims")
      shape = routine(c, "ash_onetime_maintenance_shape")
      cleanup = routine(c, "ash_onetime_cleanup_nonce")

      nullability =
        "SELECT attnotnull FROM pg_attribute WHERE attrelid=$1::text::regclass AND attname=$2 AND NOT attisdropped"

      columns = "SELECT #{shape}('#{table}'::regclass::oid)->'columns'"
      original_columns = scalar(c.owner_repo, columns)
      assert scalar(c.owner_repo, nullability, [table, @column]) == @original_not_null
      assert scalar(c.maintainer_repo, "SELECT #{cleanup}(1)") == 0

      try do
        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{table} ALTER COLUMN #{@column} #{@operation} NOT NULL",
          []
        )

        changed_columns = scalar(c.owner_repo, columns)

        # Compare the column capture itself: constraint rows can also change.
        refute changed_columns == original_columns
        assert scalar(c.owner_repo, nullability, [table, @column]) == !@original_not_null

        assert Enum.find(changed_columns, &(&1["name"] == @column))["not_null"] ==
                 !@original_not_null

        assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} =
                 SQL.query(c.maintainer_repo, "SELECT #{cleanup}(1)", [])

        assert message == "untrusted_dependency: relation shape ash_onetime_nonce_claims"
      after
        SQL.query!(
          c.owner_repo,
          "ALTER TABLE #{table} ALTER COLUMN #{@column} #{@restoration} NOT NULL",
          []
        )
      end

      assert scalar(c.owner_repo, nullability, [table, @column]) == @original_not_null
      assert scalar(c.owner_repo, columns) == original_columns
      assert scalar(c.maintainer_repo, "SELECT #{cleanup}(1)") == 0
    end
  end
end
