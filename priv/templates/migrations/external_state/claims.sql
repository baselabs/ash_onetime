<%= case fragment do %>
<% :legacy_columns -> %>
<% :legacy_checks -> %>
-- rule:legacy-reference-claim-shape
CHECK (
  (state = 'processing' AND response_partition IS NULL AND response_codec IS NULL AND response_digest IS NULL)
  OR
  (state = 'complete' AND response_partition IS NOT NULL AND response_codec IS NOT NULL
    AND response_digest IS NOT NULL
    AND octet_length(response_codec) >= 1 AND octet_length(response_codec) <= 128
    AND octet_length(response_digest) = 32)
)
<% :columns -> %>
effect_local boolean NOT NULL DEFAULT false,
effect_attempt bigint NOT NULL DEFAULT 0,
response_retain_until timestamptz NOT NULL,
response_expired_at timestamptz,
<% :checks -> %>
-- rule:claims-check-effect
CONSTRAINT ash_onetime_idempotency_claims_effect_check CHECK (NOT effect_local OR effect_attempt = 0),
-- rule:claims-check-processing
CONSTRAINT ash_onetime_idempotency_claims_processing_check CHECK (
  state <> 'processing' OR (response_partition IS NULL AND response_codec IS NULL
    AND response_digest IS NULL AND response_expired_at IS NULL)),
-- rule:claims-check-expired
CONSTRAINT ash_onetime_idempotency_claims_complete_check CHECK (
  state <> 'complete' OR
  (response_expired_at IS NULL AND response_partition IS NOT NULL AND response_codec IS NOT NULL
    AND response_digest IS NOT NULL AND octet_length(response_codec) >= 1
    AND octet_length(response_codec) <= 128 AND octet_length(response_digest) = 32)
  OR (response_expired_at IS NOT NULL AND response_partition IS NULL
    AND response_codec IS NULL AND response_digest IS NULL)),
-- rule:claims-check-deadline-order
CONSTRAINT ash_onetime_idempotency_claims_deadline_order_check CHECK (response_retain_until <= retain_until)
<% :trigger -> %>
DECLARE
  payload_count bigint;
BEGIN
  -- rule:claim-trigger-replica-branch
  IF TG_OP = 'INSERT' AND NEW.response_retain_until IS NULL THEN
    -- rule:claim-trigger-derive-insert
    NEW.response_retain_until := NEW.retain_until;
  ELSIF TG_OP = 'UPDATE' AND NEW.retain_until IS DISTINCT FROM OLD.retain_until
    AND NEW.response_retain_until IS NOT DISTINCT FROM OLD.response_retain_until THEN
    -- rule:claim-trigger-derive-update
    NEW.response_retain_until := OLD.response_retain_until
      + ((extract(epoch FROM NEW.retain_until) - extract(epoch FROM OLD.retain_until)) * interval '1 second');
  END IF;
  -- rule:claim-trigger-replica-trusted
  IF pg_catalog.current_setting('session_replication_role') = 'replica'
    AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    -- rule:claim-trigger-insert-shape
    IF NOT (NEW.state = 'processing' AND NEW.effect_attempt IN (0, 1)) THEN
      RAISE EXCEPTION 'idempotency claim insert must be processing at its initial attempt' USING ERRCODE = '23514';
    END IF;
    -- rule:claim-trigger-insert-time
    IF NEW.admitted_at IS DISTINCT FROM transaction_timestamp()
      OR NEW.inserted_at IS DISTINCT FROM transaction_timestamp() THEN
      RAISE EXCEPTION 'idempotency claim insert timestamps must be transaction_timestamp()' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  -- rule:claim-trigger-retain-clamp
  NEW.retain_until := GREATEST(OLD.retain_until, NEW.retain_until);
  -- rule:claim-trigger-response-retain-clamp
  NEW.response_retain_until := GREATEST(OLD.response_retain_until, NEW.response_retain_until);
  -- rule:claim-trigger-identity-id
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'idempotency claim identity id is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-logical_partition
  IF NEW.logical_partition IS DISTINCT FROM OLD.logical_partition THEN
    RAISE EXCEPTION 'idempotency claim identity logical_partition is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-operation_hash
  IF NEW.operation_hash IS DISTINCT FROM OLD.operation_hash THEN
    RAISE EXCEPTION 'idempotency claim identity operation_hash is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-scope_hash
  IF NEW.scope_hash IS DISTINCT FROM OLD.scope_hash THEN
    RAISE EXCEPTION 'idempotency claim identity scope_hash is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-key_hash
  IF NEW.key_hash IS DISTINCT FROM OLD.key_hash THEN
    RAISE EXCEPTION 'idempotency claim identity key_hash is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-fingerprint
  IF NEW.fingerprint IS DISTINCT FROM OLD.fingerprint THEN
    RAISE EXCEPTION 'idempotency claim identity fingerprint is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-effect_local
  IF NEW.effect_local IS DISTINCT FROM OLD.effect_local THEN
    RAISE EXCEPTION 'idempotency claim identity effect_local is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-admitted_at
  IF NEW.admitted_at IS DISTINCT FROM OLD.admitted_at THEN
    RAISE EXCEPTION 'idempotency claim identity admitted_at is immutable' USING ERRCODE = '23514';
  END IF;
  -- rule:claim-trigger-identity-inserted_at
  IF NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
    RAISE EXCEPTION 'idempotency claim identity inserted_at is immutable' USING ERRCODE = '23514';
  END IF;

  IF NEW.effect_attempt IS DISTINCT FROM OLD.effect_attempt THEN
    -- rule:claim-trigger-attempt-step
    IF NOT (NEW.effect_attempt = OLD.effect_attempt + 1) THEN
      RAISE EXCEPTION 'idempotency claim attempt must advance exactly one' USING ERRCODE = '23514';
    END IF;
    -- rule:claim-trigger-attempt-processing
    IF NOT (OLD.state = 'processing' AND NEW.state = 'processing') THEN
      RAISE EXCEPTION 'only processing idempotency claims can grant an attempt' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF OLD.state = 'complete' AND
    ROW(NEW.response_partition, NEW.response_codec, NEW.response_digest, NEW.response_expired_at)
      IS DISTINCT FROM ROW(OLD.response_partition, OLD.response_codec, OLD.response_digest, OLD.response_expired_at) THEN
    IF OLD.response_expired_at IS NULL AND NEW.response_expired_at IS NOT NULL THEN
    -- rule:claim-trigger-expire-step
    -- rule:claim-trigger-inline-active
    IF NOT (coalesce(current_setting('ash_onetime.maintenance', true) = 'on', false)
      AND current_user = (SELECT r.rolname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_roles r ON r.oid=c.relowner WHERE c.oid=TG_RELID)) THEN
      RAISE EXCEPTION 'response expiry requires an active owner maintenance step' USING ERRCODE = '23514';
    END IF;
    -- rule:claim-trigger-expire-held
    IF NOT (OLD.hold_reference IS NULL) THEN
      RAISE EXCEPTION 'held idempotency response cannot expire' USING ERRCODE = '23514';
    END IF;
    -- rule:claim-trigger-expire-early
    -- rule:claim-trigger-inline-eligible
    IF NOT (transaction_timestamp() > OLD.response_retain_until) THEN
      RAISE EXCEPTION 'idempotency response is inside its retention horizon' USING ERRCODE = '23514';
    END IF;
    SELECT count(*) INTO payload_count FROM @schema@.ash_onetime_response_payloads
      WHERE logical_partition=OLD.logical_partition AND claim_id=OLD.id;
    -- rule:claim-trigger-expire-payload
    IF NOT (payload_count = 0) THEN
      RAISE EXCEPTION 'expired idempotency response still carries a payload' USING ERRCODE = '23514';
    END IF;
    ELSE
      -- rule:claim-trigger-response-fixed
      RAISE EXCEPTION 'completed idempotency response is immutable except for maintenance expiry' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF OLD.state = 'processing' AND NEW.state = 'complete' THEN
    SELECT count(*) INTO payload_count FROM @schema@.ash_onetime_response_payloads
      WHERE logical_partition=NEW.logical_partition AND claim_id=NEW.id;
    -- rule:claim-trigger-completion-count
    IF NOT (payload_count = 1) THEN
      RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE = '23514';
    END IF;
    -- rule:claim-trigger-completion-locator
    IF NOT EXISTS (SELECT 1 FROM @schema@.ash_onetime_response_payloads
      WHERE logical_partition=NEW.logical_partition AND claim_id=NEW.id AND partition_date=NEW.response_partition) THEN
      RAISE EXCEPTION 'completed idempotency claim payload locator mismatch' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END
<% :trigger_attachment -> %>
    EXECUTE format('CREATE TRIGGER ash_onetime_idempotency_update_guard BEFORE INSERT OR UPDATE ON %I.ash_onetime_idempotency_claims FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_idempotency_update()',install_schema,routine_schema);
    -- rule:always-claim-trigger
    EXECUTE format('ALTER TABLE %I.ash_onetime_idempotency_claims ENABLE ALWAYS TRIGGER ash_onetime_idempotency_update_guard',install_schema);
<% end %>
