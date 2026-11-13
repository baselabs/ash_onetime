defmodule <%= inspect(module) %> do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @abandonment_floor_seconds 86_400
  @claims "ash_onetime_idempotency_claims"
  @cleanup "ash_onetime_idempotency_claims_cleanup_index"
  @hold "ash_onetime_idempotency_claims_hold_index"
  @full "ash_onetime_idempotency_claims_retain_until_index"
  @check "ash_onetime_idempotency_claims_hold_check"

  def up do
    execute("ALTER TABLE #{q(@claims)} ADD COLUMN IF NOT EXISTS hold_reference text")
    flush()
    unless constraint_exists?() do
      execute("""
      ALTER TABLE #{q(@claims)} ADD CONSTRAINT #{qi(@check)}
      CHECK (hold_reference IS NULL OR (octet_length(hold_reference) BETWEEN 1 AND 255 AND state = 'complete')) NOT VALID
      """)
      flush()
    end
    execute("ALTER TABLE #{q(@claims)} VALIDATE CONSTRAINT #{qi(@check)}")
    flush()
    build_index(@cleanup, "retain_until", "state = 'complete' AND hold_reference IS NULL")
    build_index(@hold, "logical_partition, hold_reference", "hold_reference IS NOT NULL")
    drop_index(@full)
    install_hold_functions()
  end

  def down do
    # A downgrade must not silently discard a live operation's retention protection.
    execute("""
    DO $down$
    BEGIN
      -- Refuse a narrowed proof of absence under row security.
      PERFORM pg_catalog.set_config('row_security', 'off', true);
      IF EXISTS (SELECT 1 FROM #{q(@claims)} WHERE hold_reference IS NOT NULL) THEN
        RAISE EXCEPTION 'release operation holds before removing operation-hold support' USING ERRCODE = '23514';
      END IF;
    END
    $down$
    """)
    flush()
    build_index(@full, "retain_until", nil)
    install_previous_functions()
    flush()
    drop_index(@cleanup)
    drop_index(@hold)
    execute("ALTER TABLE #{q(@claims)} DROP CONSTRAINT #{qi(@check)}, DROP COLUMN hold_reference")
  end

  defp constraint_exists? do
    query!("SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid = $1::text::regclass AND conname = $2", [q(@claims), @check]).num_rows == 1
  end

  defp build_index(name, columns, predicate) do
    unless query!("SELECT 1 FROM pg_catalog.pg_index WHERE indexrelid = pg_catalog.to_regclass($1) AND indisvalid", [q(name)]).num_rows == 1 do
      build_missing_index(name, columns, predicate)
    end
  end

  defp build_missing_index(name, columns, predicate) do
    case query!("SELECT relkind FROM pg_catalog.pg_class WHERE oid = $1::text::regclass", [q(@claims)]).rows do
      [["p"]] ->
        ensure_index(name, q(@claims), columns, predicate, true)
        children = query!("SELECT n.nspname, c.relname FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE i.inhparent = $1::text::regclass ORDER BY c.relname", [q(@claims)]).rows
        for {[schema, child], ordinal} <- Enum.with_index(children) do
          child_name = name <> "_p#{ordinal}"
          child_index = qi(schema) <> "." <> qi(child_name)
          ensure_index(child_name, qi(schema) <> "." <> qi(child), columns, predicate, false, child_index)
          unless query!("SELECT 1 FROM pg_catalog.pg_inherits WHERE inhparent = $1::text::regclass AND inhrelid = $2::text::regclass", [q(name), child_index]).num_rows == 1 do
            execute("ALTER INDEX #{q(name)} ATTACH PARTITION #{child_index}")
            flush()
          end
        end
      [["r"]] -> ensure_index(name, q(@claims), columns, predicate, false)
    end
  end

  defp ensure_index(name, table, columns, predicate, parent?, qualified \\ nil) do
    qualified = qualified || q(name)
    existing = query!("SELECT i.indisvalid, c.relkind FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid WHERE i.indexrelid = pg_catalog.to_regclass($1)", [qualified]).rows
    # Partitioned parents stay INVALID until all children are attached. A failed concurrent
    # heap-index build, however, must be dropped before retrying: IF NOT EXISTS would retain it.
    if existing == [[false, "i"]] do
      execute("DROP INDEX CONCURRENTLY #{qualified}")
      flush()
    end
    if existing == [] or existing == [[false, "i"]] do
      concurrent = if parent?, do: "", else: "CONCURRENTLY "
      only = if parent?, do: "ONLY ", else: ""
      where = if predicate, do: " WHERE " <> predicate, else: ""
      execute("CREATE INDEX #{concurrent}#{qi(name)} ON #{only}#{table} (#{columns})#{where}")
      flush()
    end
  end

  defp drop_index(name) do
    case query!("SELECT relkind FROM pg_catalog.pg_class WHERE oid = pg_catalog.to_regclass($1)", [q(name)]).rows do
      [] -> :ok
      [[kind]] ->
        concurrent = if kind == "I", do: "", else: "CONCURRENTLY "
        execute("DROP INDEX #{concurrent}#{q(name)}")
        flush()
    end
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(repo(), sql, params)

  defp q(name) do
    case prefix() do
      nil -> qi(name)
      schema -> qi(schema) <> "." <> qi(name)
    end
  end
  defp qi(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp install_hold_functions do
    execute("""
    CREATE OR REPLACE FUNCTION #{q("ash_onetime_guard_idempotency_delete")}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $guard$
    DECLARE
      payload_count integer;
      reap_before text;
    BEGIN
      IF OLD.hold_reference IS NOT NULL THEN
        RAISE EXCEPTION 'held idempotency claim cannot be deleted; release its operation hold first'
          USING ERRCODE = '23514';
      END IF;

      IF OLD.state = 'processing' THEN
        -- Processing rows are recovery points. They are deletable only inside a sanctioned reap:
        -- the reaper arms the ash_onetime.reap_before session variable, and even then only a row
        -- older than BOTH that cutoff and the hard floor AND past its own retention horizon may
        -- go. Anything else RAISEs, exactly as before.
        reap_before := current_setting('ash_onetime.reap_before', true);

        IF reap_before IS NULL OR reap_before = '' THEN
          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'
            USING ERRCODE = '23514';
        END IF;

        IF OLD.inserted_at >= reap_before::timestamptz
           OR OLD.inserted_at >= transaction_timestamp() - (#{@abandonment_floor_seconds} * interval '1 second')
           OR NOT #{q("ash_onetime_cleanup_eligible")}(OLD.retain_until) THEN
          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'
            USING ERRCODE = '23514';
        END IF;

        SELECT count(*) INTO payload_count
        FROM #{q("ash_onetime_response_payloads")}
        WHERE logical_partition = OLD.logical_partition AND claim_id = OLD.id;
        IF payload_count <> 0 THEN
          RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload'
            USING ERRCODE = '23514';
        END IF;

        RETURN OLD;
      END IF;

      IF NOT #{q("ash_onetime_cleanup_eligible")}(OLD.retain_until) THEN
        RAISE EXCEPTION 'idempotency claim is inside its retention horizon'
          USING ERRCODE = '23514';
      END IF;

      SELECT count(*) INTO payload_count
      FROM #{q("ash_onetime_response_payloads")}
      WHERE logical_partition = OLD.logical_partition
        AND partition_date = OLD.response_partition AND claim_id = OLD.id;
      IF payload_count <> 1 THEN
        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'
          USING ERRCODE = '23514';
      END IF;

      DELETE FROM #{q("ash_onetime_response_payloads")}
      WHERE logical_partition = OLD.logical_partition
        AND partition_date = OLD.response_partition AND claim_id = OLD.id;
      GET DIAGNOSTICS payload_count = ROW_COUNT;
      IF payload_count <> 1 THEN
        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'
          USING ERRCODE = '23514';
      END IF;

      RETURN OLD;
    END
    $guard$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{q("ash_onetime_cleanup_idempotency")}(batch_size integer)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $cleanup$
    DECLARE deleted_count bigint;
    BEGIN
      IF batch_size < 1 OR batch_size > 10000 THEN
        RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';
      END IF;

      WITH candidates AS (
        SELECT logical_partition, operation_hash, id
        FROM #{q("ash_onetime_idempotency_claims")}
        WHERE state = 'complete'
          AND hold_reference IS NULL
          AND #{q("ash_onetime_cleanup_eligible")}(retain_until)
        ORDER BY retain_until, logical_partition, operation_hash, id
        FOR UPDATE SKIP LOCKED
        LIMIT batch_size
      ), deleted AS (
        DELETE FROM #{q("ash_onetime_idempotency_claims")} claims
        USING candidates
        WHERE claims.logical_partition = candidates.logical_partition AND claims.operation_hash = candidates.operation_hash AND claims.id = candidates.id
        RETURNING claims.id
      )
      SELECT count(*) INTO deleted_count FROM deleted;
      RETURN deleted_count;
    END
    $cleanup$
    """)

  end

  defp install_previous_functions do
    execute("""
    CREATE OR REPLACE FUNCTION #{q("ash_onetime_guard_idempotency_delete")}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $guard$
    DECLARE
      payload_count integer;
      reap_before text;
    BEGIN
      IF OLD.state = 'processing' THEN
        -- Processing rows are recovery points. They are deletable only inside a sanctioned reap:
        -- the reaper arms the ash_onetime.reap_before session variable, and even then only a row
        -- older than BOTH that cutoff and the hard floor AND past its own retention horizon may
        -- go. Anything else RAISEs, exactly as before.
        reap_before := current_setting('ash_onetime.reap_before', true);

        IF reap_before IS NULL OR reap_before = '' THEN
          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'
            USING ERRCODE = '23514';
        END IF;

        IF OLD.inserted_at >= reap_before::timestamptz
           OR OLD.inserted_at >= transaction_timestamp() - (#{@abandonment_floor_seconds} * interval '1 second')
           OR NOT #{q("ash_onetime_cleanup_eligible")}(OLD.retain_until) THEN
          RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'
            USING ERRCODE = '23514';
        END IF;

        SELECT count(*) INTO payload_count
        FROM #{q("ash_onetime_response_payloads")}
        WHERE logical_partition = OLD.logical_partition AND claim_id = OLD.id;
        IF payload_count <> 0 THEN
          RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload'
            USING ERRCODE = '23514';
        END IF;

        RETURN OLD;
      END IF;

      IF NOT #{q("ash_onetime_cleanup_eligible")}(OLD.retain_until) THEN
        RAISE EXCEPTION 'idempotency claim is inside its retention horizon'
          USING ERRCODE = '23514';
      END IF;

      SELECT count(*) INTO payload_count
      FROM #{q("ash_onetime_response_payloads")}
      WHERE logical_partition = OLD.logical_partition
        AND partition_date = OLD.response_partition AND claim_id = OLD.id;
      IF payload_count <> 1 THEN
        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'
          USING ERRCODE = '23514';
      END IF;

      DELETE FROM #{q("ash_onetime_response_payloads")}
      WHERE logical_partition = OLD.logical_partition
        AND partition_date = OLD.response_partition AND claim_id = OLD.id;
      GET DIAGNOSTICS payload_count = ROW_COUNT;
      IF payload_count <> 1 THEN
        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'
          USING ERRCODE = '23514';
      END IF;

      RETURN OLD;
    END
    $guard$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{q("ash_onetime_cleanup_idempotency")}(batch_size integer)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $cleanup$
    DECLARE deleted_count bigint;
    BEGIN
      IF batch_size < 1 OR batch_size > 10000 THEN
        RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';
      END IF;

      WITH candidates AS (
        SELECT logical_partition, operation_hash, id
        FROM #{q("ash_onetime_idempotency_claims")}
        WHERE state = 'complete'
          AND #{q("ash_onetime_cleanup_eligible")}(retain_until)
        ORDER BY retain_until, logical_partition, operation_hash, id
        FOR UPDATE SKIP LOCKED
        LIMIT batch_size
      ), deleted AS (
        DELETE FROM #{q("ash_onetime_idempotency_claims")} claims
        USING candidates
        WHERE claims.logical_partition = candidates.logical_partition AND claims.operation_hash = candidates.operation_hash AND claims.id = candidates.id
        RETURNING claims.id
      )
      SELECT count(*) INTO deleted_count FROM deleted;
      RETURN deleted_count;
    END
    $cleanup$
    """)

  end
end
