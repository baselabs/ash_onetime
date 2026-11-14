defmodule <%= inspect(module) %> do
  @moduledoc false

  use Ecto.Migration

  # SEC-5/SEC-6 forward migration for existing installs:
  #   1. add the response_partition index (SEC-6) — CREATE INDEX IF NOT EXISTS.
  #   2. back-fill monthly response_payloads range partitions from the install partition-start
  #      through now+N, so payloads no longer route to _default for the elapsed+forward window.
  #   3. drain past-retention claims whose payload is stranded in _default — CLAIM-SCOPED, not
  #      payload-direct, so the existing ash_onetime_guard_idempotency_delete trigger removes
  #      the payload and the cardinality invariant (payload_count = 1) stays satisfied. Within-
  #      retention stranded payloads are left (re-completion under a new key is a new execution).
  #
  # Idempotent: CREATE INDEX IF NOT EXISTS, CREATE TABLE IF NOT EXISTS, and the drain matches
  # only past-retention rows (a re-run drains whatever newly aged out).

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS ash_onetime_idempotency_claims_response_partition_index
    ON #{q("ash_onetime_idempotency_claims")} (response_partition)
    """)

    for %{name: name, from: from, to: to} <- <%= inspect(partitions) %> do
      execute("""
      CREATE TABLE IF NOT EXISTS #{q(name)} PARTITION OF #{q("ash_onetime_response_payloads")}
      FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(to)}')
      """)
    end

    execute("""
    DELETE FROM #{q("ash_onetime_idempotency_claims")}
    WHERE state = 'complete'
      AND #{q("ash_onetime_cleanup_eligible")}(retain_until)
      AND id IN (
        SELECT claim_id
        FROM #{q("ash_onetime_response_payloads")}
        WHERE tableoid IN (
          SELECT oid FROM pg_class
          WHERE relname = 'ash_onetime_response_payloads_default'
            AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = #{schema_name()})
        )
      )
    """)
  end

  def down do
    # The index and any created partitions are forward-only additions; the drain deleted only
    # past-retention data that the normal cleanup path would also delete. A down is a no-op:
    # the index is benign, the partitions are empty forward months, and the drained claims were
    # past retention. We do not recreate past-retention state on rollback.
    :ok
  end

  defp q(name) do
    case prefix() do
      nil -> quote_identifier(name)
      prefix_value -> quote_identifier(prefix_value) <> "." <> quote_identifier(name)
    end
  end

  # The namespace the drain's _default OID subquery scopes to. ecto_sql does NOT set
  # search_path for prefixed migrations, so current_schema() resolves to the connection
  # default (typically 'public'), NOT the migration's prefix — using current_schema() here
  # would make a prefixed (multi-tenant) drain silently miss the tenant's _default partition
  # and drain zero rows. Resolve from prefix() (the migration's actual schema), falling back
  # to current_schema() only for the nil-prefix (single-tenant) case — mirroring the store's
  # `target.prefix || schema` pattern (postgres.ex database_schema_and_date/1).
  defp schema_name do
    case prefix() do
      nil -> "current_schema()"
      prefix_value -> "'#{prefix_value}'"
    end
  end

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
end
