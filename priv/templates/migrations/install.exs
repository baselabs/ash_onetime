defmodule <%= inspect(module) %> do
  use Ecto.Migration

  @payload_ceiling 16_777_216
  @install_prefix <%= inspect(install_prefix) %>

  <%= EEx.eval_file(Path.join(__DIR__, "maintenance_helpers.exs"), binding()) %>

  def up do
    execute("""
    CREATE TABLE #{q("ash_onetime_idempotency_claims")} (
      id uuid <%= if hash_partitions, do: "NOT NULL", else: "PRIMARY KEY" %>,
      logical_partition text NOT NULL DEFAULT 'global'
        CHECK (octet_length(logical_partition) BETWEEN 1 AND 255),
      operation_hash bytea NOT NULL CHECK (octet_length(operation_hash) = 32),
      scope_hash bytea NOT NULL CHECK (octet_length(scope_hash) = 32),
      key_hash bytea NOT NULL CHECK (octet_length(key_hash) = 32),
      fingerprint bytea NOT NULL CHECK (octet_length(fingerprint) = 32),
      state text NOT NULL DEFAULT 'processing' CHECK (state IN ('processing', 'complete')),
      response_partition date,
      response_codec text,
      response_digest bytea,
      hold_reference text CONSTRAINT ash_onetime_idempotency_claims_hold_check
        CHECK (hold_reference IS NULL OR (octet_length(hold_reference) >= 1 AND octet_length(hold_reference) <= 255 AND state = 'complete')),
      admitted_at timestamptz NOT NULL,
      retain_until timestamptz NOT NULL,
      inserted_at timestamptz NOT NULL,
      <%= collision_constraint %>,
      <%= if hash_partitions, do: "PRIMARY KEY (operation_hash, logical_partition, id)," %>
      CHECK (retain_until > admitted_at),
      CHECK (inserted_at >= admitted_at),
      CHECK (
        (state = 'processing' AND response_partition IS NULL AND response_codec IS NULL AND response_digest IS NULL)
        OR
        (state = 'complete' AND response_partition IS NOT NULL AND response_codec IS NOT NULL
          AND response_digest IS NOT NULL
          AND octet_length(response_codec) >= 1 AND octet_length(response_codec) <= 128
          AND octet_length(response_digest) = 32)
      )
    ) <%= if hash_partitions, do: "PARTITION BY HASH (operation_hash)", else: "USING heap" %>
    """)

    create_claim_partitions("ash_onetime_idempotency_claims")

    execute("""
    CREATE INDEX ash_onetime_idempotency_claims_cleanup_index
    ON #{q("ash_onetime_idempotency_claims")} (retain_until)
    WHERE state = 'complete' AND hold_reference IS NULL
    """)

    execute("""
    CREATE INDEX ash_onetime_idempotency_claims_hold_index
    ON #{q("ash_onetime_idempotency_claims")} (logical_partition, hold_reference)
    WHERE hold_reference IS NOT NULL
    """)

    execute("""
    CREATE INDEX ash_onetime_idempotency_claims_processing_index
    ON #{q("ash_onetime_idempotency_claims")} (inserted_at)
    WHERE state = 'processing'
    """)

    execute("""
    CREATE INDEX ash_onetime_idempotency_claims_response_partition_index
    ON #{q("ash_onetime_idempotency_claims")} (response_partition)
    """)

    execute("""
    CREATE TABLE #{q("ash_onetime_nonce_claims")} (
      id uuid <%= if hash_partitions, do: "NOT NULL", else: "PRIMARY KEY" %>,
      logical_partition text NOT NULL DEFAULT 'global'
        CHECK (octet_length(logical_partition) BETWEEN 1 AND 255),
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
      <%= if hash_partitions, do: "PRIMARY KEY (operation_hash, logical_partition, id)," %>
      CHECK (expires_at IS NULL OR expires_at >= issued_at),
      CHECK (retain_until > issued_at),
      CHECK (retain_until > admitted_at),
      CHECK (inserted_at >= admitted_at)
    ) <%= if hash_partitions, do: "PARTITION BY HASH (operation_hash)", else: "USING heap" %>
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
    execute("DROP FUNCTION IF EXISTS #{rq("ash_onetime_reap_idempotency")}(integer, bigint)")
    execute("DROP FUNCTION IF EXISTS #{rq("ash_onetime_cleanup_nonce")}(integer)")
    execute("DROP FUNCTION IF EXISTS #{rq("ash_onetime_cleanup_idempotency")}(integer)")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_nonce_claims")} CASCADE")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_idempotency_claims")} CASCADE")
    execute("DROP FUNCTION IF EXISTS #{rq("ash_onetime_guard_nonce_delete")}()")
    execute("DROP FUNCTION IF EXISTS #{rq("ash_onetime_guard_idempotency_delete")}()")
    execute("DROP FUNCTION IF EXISTS #{rq("ash_onetime_cleanup_eligible")}(timestamptz)")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_response_payloads")} CASCADE")
    execute("DROP TABLE IF EXISTS #{q("ash_onetime_maintenance_runs")} CASCADE")
    for routine <- @maintenance_functions do
      execute("DROP FUNCTION IF EXISTS #{rq(routine.name)}(#{routine.args})")
    end
    execute("DROP SCHEMA #{quote_identifier(routine_schema_name())}")
  end

  defp create_payloads do
    execute("""
    CREATE TABLE #{q("ash_onetime_response_payloads")} (
      logical_partition text NOT NULL DEFAULT 'global'
        CHECK (octet_length(logical_partition) BETWEEN 1 AND 255),
      partition_date date NOT NULL,
      claim_id uuid NOT NULL,
      encoded_response bytea NOT NULL CHECK (octet_length(encoded_response) <= #{@payload_ceiling}),
      PRIMARY KEY (logical_partition, partition_date, claim_id)
    ) PARTITION BY RANGE (partition_date)
    """)

    <%= if relative_partitions do %>
    execute("DO " <> maintenance_literal("""
    DECLARE
      install_schema text;
      first_month date := date_trunc('month',transaction_timestamp())::date;
      month_date date;
      next_month date;
      ordinal integer;
    BEGIN
      SELECT n.nspname INTO STRICT install_schema FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid=#{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass;
      FOR ordinal IN 0..12 LOOP
        month_date := (first_month+ordinal*interval '1 month')::date;
        next_month := (month_date+interval '1 month')::date;
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.ash_onetime_response_payloads FOR VALUES FROM (%L) TO (%L) USING heap',
          install_schema,'ash_onetime_response_payloads_' || to_char(month_date,'YYYY_MM'),install_schema,month_date,next_month);
      END LOOP;
    END
    """))
    <% else %>
    for %{name: name, from: from, to: to} <- <%= inspect(response_partitions) %> do
      execute("""
      CREATE TABLE #{q(name)} PARTITION OF #{q("ash_onetime_response_payloads")}
      FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(to)}') USING heap
      """)
    end
    <% end %>

    execute("""
    CREATE TABLE #{q("ash_onetime_response_payloads_default")}
    PARTITION OF #{q("ash_onetime_response_payloads")} DEFAULT USING heap
    """)
  end

  defp create_claim_partitions(parent) do
    <%= if hash_partitions do %>
    count = <%= hash_partitions %>

    for remainder <- 0..(count - 1) do
      execute("""
      CREATE TABLE #{q("#{parent}_p#{remainder}")}
      PARTITION OF #{q(parent)}
      FOR VALUES WITH (MODULUS #{count}, REMAINDER #{remainder}) USING heap
      """)
    end
    <% else %>
    _ = parent
    :ok
    <% end %>
  end

  defp create_cleanup_functions do
    install_maintenance(:fresh)
  end


  defp q(name) do
    case @install_prefix || prefix() do
      nil -> quote_identifier(name)
      prefix -> quote_identifier(prefix) <> "." <> quote_identifier(name)
    end
  end

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
end
