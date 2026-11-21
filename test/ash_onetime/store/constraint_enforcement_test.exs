defmodule AshOnetime.Store.ConstraintEnforcementTest do
  use AshOnetime.Test.ExternalStateCase, async: false

  @tag :maintenance_constraint_enforcement
  test "native constraint enforcement is preserved in maintenance shapes", c do
    table = rel(c, "ash_onetime_nonce_claims")
    shape = routine(c, "ash_onetime_maintenance_shape")
    cleanup = routine(c, "ash_onetime_cleanup_nonce")
    before = scalar(c.owner_repo, "SELECT #{shape}('#{table}'::regclass::oid)")
    assert before["constraints"] != []
    assert Enum.all?(before["constraints"], &(&1["enforced"] == true))
    assert scalar(c.maintainer_repo, "SELECT #{cleanup}(1)") == 0

    supports_enforcement_flag =
      scalar(
        c.owner_repo,
        "SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='pg_constraint'::regclass AND attname='conenforced' AND NOT attisdropped)"
      )

    disable =
      "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_nonce_claims_key_hash_check, ADD CONSTRAINT ash_onetime_nonce_claims_key_hash_check CHECK (octet_length(key_hash) = 32) NOT ENFORCED"

    if supports_enforcement_flag do
      SQL.query!(c.owner_repo, disable, [])
      changed = scalar(c.owner_repo, "SELECT #{shape}('#{table}'::regclass::oid)")
      assert false in Enum.map(changed["constraints"], & &1["enforced"])

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001", message: message}}} =
               SQL.query(c.maintainer_repo, "SELECT #{cleanup}(1)", [])

      assert message == "untrusted_dependency: relation shape ash_onetime_nonce_claims"

      SQL.query!(
        c.owner_repo,
        "ALTER TABLE #{table} DROP CONSTRAINT ash_onetime_nonce_claims_key_hash_check, ADD CONSTRAINT ash_onetime_nonce_claims_key_hash_check CHECK (octet_length(key_hash) = 32) ENFORCED",
        []
      )

      assert scalar(c.owner_repo, "SELECT #{shape}('#{table}'::regclass::oid)") == before
      assert scalar(c.maintainer_repo, "SELECT #{cleanup}(1)") == 0
    else
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42601"}}} =
               SQL.query(c.owner_repo, disable, [])

      assert scalar(c.maintainer_repo, "SELECT #{cleanup}(1)") == 0
    end
  end
end
