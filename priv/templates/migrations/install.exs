defmodule <%= inspect(module) %> do
  use Ecto.Migration

  @payload_ceiling 16_777_216

  def up do
    execute("""
    CREATE TABLE #{q("ash_onetime_idempotency_claims")} (
      id uuid <%= if hash_partitions, do: "NOT NULL", else: "PRIMARY KEY" %>,
      operation_hash bytea NOT NULL CHECK (octet_length(operation_hash) = 32),
      scope_hash bytea NOT NULL CHECK (octet_length(scope_hash) = 32),
      key_hash bytea NOT NULL CHECK (octet_length(key_hash) = 32),
      fingerprint bytea NOT NULL CHECK (octet_length(fingerprint) = 32),
      state text NOT NULL DEFAULT 'processing' CHECK (state IN ('processing', 'complete')),
      response_partition date,
      response_codec text,
      response_digest bytea,
      admitted_at timestamptz NOT NULL,
      retain_until timestamptz NOT NULL,
      inserted_at timestamptz NOT NULL,
      <%= collision_constraint %>,
      <%= if hash_partitions, do: "PRIMARY KEY (operation_hash, id)," %>
      CHECK (retain_until > admitted_at),
      CHECK (inserted_at >= admitted_at),
      CHECK (
        (state = 'processing' AND response_partition IS NULL AND response_codec IS NULL AND response_digest IS NULL)
        OR
        (state = 'complete' AND response_partition IS NOT NULL AND response_codec IS NOT NULL
          AND response_digest IS NOT NULL
          AND octet_length(response_codec) BETWEEN 1 AND 128
          AND octet_length(response_digest) = 32)
      )
    ) <%= if hash_partitions, do: "PARTITION BY HASH (operation_hash)" %>
    """)

    create_claim_partitions("ash_onetime_idempotency_claims")

    execute("""
    CREATE INDEX ash_onetime_idempotency_claims_retain_until_index
    ON #{q("ash_onetime_idempotency_claims")} (retain_until)
    """)

    execute("""
    CREATE TABLE #{q("ash_onetime_nonce_claims")} (
      id uuid <%= if hash_partitions, do: "NOT NULL", else: "PRIMARY KEY" %>,
      operation_hash bytea NOT NULL CHECK (octet_length(operation_hash) = 32),
      scope_hash bytea NOT NULL CHECK (octet_length(scope_hash) = 32),
      key_hash bytea NOT NULL CHECK (octet_length(key_hash) = 32),
      issued_at timestamptz NOT NULL,
      expires_at timestamptz,
      verifier_id text NOT NULL CHECK (octet_length(verifier_id) BETWEEN 1 AND 128),
      admitted_at timestamptz NOT NULL,
      retain_until timestamptz NOT NULL,
      inserted_at timestamptz NOT NULL,
      <%= collision_constraint %>,
      <%= if hash_partitions, do: "PRIMARY KEY (operation_hash, id)," %>
      CHECK (expires_at IS NULL OR expires_at >= issued_at),
      CHECK (retain_until > issued_at),
      CHECK (retain_until > admitted_at),
      CHECK (inserted_at >= admitted_at)
    ) <%= if hash_partitions, do: "PARTITION BY HASH (operation_hash)" %>
    """)

    create_claim_partitions("ash_onetime_nonce_claims")

    execute("""
    CREATE INDEX ash_onetime_nonce_claims_retain_until_index
    ON #{q("ash_onetime_nonce_claims")} (retain_until)
    """)

    create_payloads()
    create_cleanup_functions()
  end

  def down do
    execute("DROP FUNCTION IF EXISTS #{q("ash_onetime_cleanup_nonce")}(integer)")
    execute("DROP FUNCTION IF EXISTS #{q("ash_onetime_cleanup_idempotency")}(integer)")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_nonce_claims")} CASCADE")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_idempotency_claims")} CASCADE")
    execute("DROP FUNCTION IF EXISTS #{q("ash_onetime_guard_nonce_delete")}()")
    execute("DROP FUNCTION IF EXISTS #{q("ash_onetime_guard_idempotency_delete")}()")
    execute("DROP FUNCTION IF EXISTS #{q("ash_onetime_cleanup_eligible")}(timestamptz)")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_response_payloads")} CASCADE")
  end

  defp create_payloads do
    execute("""
    CREATE TABLE #{q("ash_onetime_response_payloads")} (
      partition_date date NOT NULL,
      claim_id uuid NOT NULL,
      encoded_response bytea NOT NULL CHECK (octet_length(encoded_response) <= #{@payload_ceiling}),
      PRIMARY KEY (partition_date, claim_id)
    ) PARTITION BY RANGE (partition_date)
    """)

    for %{name: name, from: from, to: to} <- <%= inspect(response_partitions) %> do
      execute("""
      CREATE TABLE #{q(name)} PARTITION OF #{q("ash_onetime_response_payloads")}
      FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(to)}')
      """)
    end

    execute("""
    CREATE TABLE #{q("ash_onetime_response_payloads_default")}
    PARTITION OF #{q("ash_onetime_response_payloads")} DEFAULT
    """)
  end

  defp create_claim_partitions(parent) do
    <%= if hash_partitions do %>
    count = <%= hash_partitions %>

    for remainder <- 0..(count - 1) do
      execute("""
      CREATE TABLE #{q("#{parent}_p#{remainder}")}
      PARTITION OF #{q(parent)}
      FOR VALUES WITH (MODULUS #{count}, REMAINDER #{remainder})
      """)
    end
    <% else %>
    _ = parent
    :ok
    <% end %>
  end

  defp create_cleanup_functions do
    execute("""
    CREATE FUNCTION #{q("ash_onetime_cleanup_eligible")}(retain_until timestamptz)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $cleanup$ SELECT transaction_timestamp() <%= cleanup_comparator %> retain_until $cleanup$
    """)

    execute("""
    CREATE FUNCTION #{q("ash_onetime_guard_idempotency_delete")}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $guard$
    DECLARE payload_count integer;
    BEGIN
      IF OLD.state = 'processing' THEN
        RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted'
          USING ERRCODE = '23514';
      END IF;

      IF NOT #{q("ash_onetime_cleanup_eligible")}(OLD.retain_until) THEN
        RAISE EXCEPTION 'idempotency claim is inside its retention horizon'
          USING ERRCODE = '23514';
      END IF;

      SELECT count(*) INTO payload_count
      FROM #{q("ash_onetime_response_payloads")}
      WHERE claim_id = OLD.id;
      IF payload_count <> 1 THEN
        RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch'
          USING ERRCODE = '23514';
      END IF;

      DELETE FROM #{q("ash_onetime_response_payloads")}
      WHERE partition_date = OLD.response_partition AND claim_id = OLD.id;
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
    CREATE TRIGGER ash_onetime_idempotency_delete_guard
    BEFORE DELETE ON #{q("ash_onetime_idempotency_claims")}
    FOR EACH ROW EXECUTE FUNCTION #{q("ash_onetime_guard_idempotency_delete")}()
    """)

    execute("""
    CREATE FUNCTION #{q("ash_onetime_guard_nonce_delete")}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $guard$
    BEGIN
      IF NOT #{q("ash_onetime_cleanup_eligible")}(OLD.retain_until) THEN
        RAISE EXCEPTION 'nonce claim is inside its retention horizon'
          USING ERRCODE = '23514';
      END IF;
      RETURN OLD;
    END
    $guard$
    """)

    execute("""
    CREATE TRIGGER ash_onetime_nonce_delete_guard
    BEFORE DELETE ON #{q("ash_onetime_nonce_claims")}
    FOR EACH ROW EXECUTE FUNCTION #{q("ash_onetime_guard_nonce_delete")}()
    """)

    execute("""
    CREATE FUNCTION #{q("ash_onetime_cleanup_idempotency")}(batch_size integer)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $cleanup$
    DECLARE deleted_count bigint;
    BEGIN
      IF batch_size < 1 OR batch_size > 10000 THEN
        RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';
      END IF;

      WITH candidates AS (
        SELECT operation_hash, id
        FROM #{q("ash_onetime_idempotency_claims")}
        WHERE state = 'complete'
          AND #{q("ash_onetime_cleanup_eligible")}(retain_until)
        ORDER BY retain_until, operation_hash, id
        FOR UPDATE SKIP LOCKED
        LIMIT batch_size
      ), deleted AS (
        DELETE FROM #{q("ash_onetime_idempotency_claims")} claims
        USING candidates
        WHERE <%= cleanup_delete_predicate %>
        RETURNING claims.id
      )
      SELECT count(*) INTO deleted_count FROM deleted;
      RETURN deleted_count;
    END
    $cleanup$
    """)

    execute("""
    CREATE FUNCTION #{q("ash_onetime_cleanup_nonce")}(batch_size integer)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $cleanup$
    DECLARE deleted_count bigint;
    BEGIN
      IF batch_size < 1 OR batch_size > 10000 THEN
        RAISE EXCEPTION 'invalid cleanup batch size' USING ERRCODE = '22023';
      END IF;

      WITH candidates AS (
        SELECT operation_hash, id
        FROM #{q("ash_onetime_nonce_claims")}
        WHERE #{q("ash_onetime_cleanup_eligible")}(retain_until)
        ORDER BY retain_until, operation_hash, id
        FOR UPDATE SKIP LOCKED
        LIMIT batch_size
      ), deleted AS (
        DELETE FROM #{q("ash_onetime_nonce_claims")} claims
        USING candidates
        WHERE <%= cleanup_delete_predicate %>
        RETURNING claims.id
      )
      SELECT count(*) INTO deleted_count FROM deleted;
      RETURN deleted_count;
    END
    $cleanup$
    """)
  end

  defp q(name) do
    case prefix() do
      nil -> quote_identifier(name)
      prefix -> quote_identifier(prefix) <> "." <> quote_identifier(name)
    end
  end

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
end
