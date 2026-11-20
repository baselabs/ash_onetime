DECLARE
  payload_count bigint;
  reap_before text;
BEGIN
  IF pg_catalog.current_setting('session_replication_role') = 'replica'
    -- rule:M-replica-admit
    AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN
    RETURN OLD;
  END IF;
  -- rule:operation-hold-delete-guard
  IF OLD.hold_reference IS NOT NULL THEN
    RAISE EXCEPTION 'held idempotency claim cannot be deleted; release its operation hold first' USING ERRCODE = '23514';
  END IF;
  IF OLD.state = 'processing' THEN
    -- rule:reap-guard-kind
    IF NOT OLD.effect_local THEN
      RAISE EXCEPTION 'unresolved or unclassified external idempotency claim cannot be deleted' USING ERRCODE='23514';
    END IF;
    reap_before := current_setting('ash_onetime.reap_before', true);
    IF reap_before IS NULL OR reap_before = '' THEN
      -- rule:current-delete-unarmed
      RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF OLD.inserted_at >= reap_before::timestamptz
       -- rule:reap-floor-guard
       OR OLD.inserted_at >= transaction_timestamp() - interval '86400 seconds'
       -- rule:reap-retention-guard
       OR NOT (transaction_timestamp() > OLD.retain_until) THEN
      RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted' USING ERRCODE = '23514';
    END IF;
    SELECT count(*) INTO payload_count FROM @schema@.ash_onetime_response_payloads
    WHERE logical_partition = OLD.logical_partition AND claim_id = OLD.id;
    IF payload_count <> 0 THEN
      -- rule:current-delete-processing-payload
      RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload' USING ERRCODE = '23514';
    END IF;
    RETURN OLD;
  END IF;
  -- rule:delete-guard-inline-eligibility
  IF NOT (transaction_timestamp() > OLD.retain_until) THEN
    RAISE EXCEPTION 'idempotency claim is inside its retention horizon' USING ERRCODE = '23514';
  END IF;
  SELECT count(*) INTO payload_count FROM @schema@.ash_onetime_response_payloads
  WHERE logical_partition = OLD.logical_partition AND claim_id = OLD.id;
  -- rule:cleanup-expired-payload-count
  IF payload_count <> (CASE WHEN OLD.response_expired_at IS NULL THEN 1 ELSE 0 END) THEN
    RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE = '23514';
  END IF;
  IF OLD.response_expired_at IS NOT NULL THEN RETURN OLD; END IF;
  DELETE FROM @schema@.ash_onetime_response_payloads
  WHERE logical_partition = OLD.logical_partition AND partition_date = OLD.response_partition AND claim_id = OLD.id;
  GET DIAGNOSTICS payload_count = ROW_COUNT;
  IF payload_count <> 1 THEN
    -- rule:current-delete-count-after
    RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END
