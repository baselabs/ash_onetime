DECLARE
  payload_count bigint;
  reap_before text;
BEGIN
  IF OLD.hold_reference IS NOT NULL THEN
    RAISE EXCEPTION 'held idempotency claim cannot be deleted; release its operation hold first' USING ERRCODE = '23514';
  END IF;
  IF OLD.state = 'processing' THEN
    reap_before := current_setting('ash_onetime.reap_before', true);
    IF reap_before IS NULL OR reap_before = '' THEN
      RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF OLD.inserted_at >= reap_before::timestamptz
       OR OLD.inserted_at >= transaction_timestamp() - interval '86400 seconds'
       OR NOT @routines@.ash_onetime_cleanup_eligible(OLD.retain_until::timestamptz) THEN
      RAISE EXCEPTION 'processing idempotency claims are recovery points and cannot be deleted' USING ERRCODE = '23514';
    END IF;
    SELECT count(*) INTO payload_count FROM @schema@.ash_onetime_response_payloads
    WHERE logical_partition = OLD.logical_partition AND claim_id = OLD.id;
    IF payload_count <> 0 THEN
      RAISE EXCEPTION 'reaped processing idempotency claim unexpectedly carries a payload' USING ERRCODE = '23514';
    END IF;
    RETURN OLD;
  END IF;
  IF NOT @routines@.ash_onetime_cleanup_eligible(OLD.retain_until::timestamptz) THEN
    RAISE EXCEPTION 'idempotency claim is inside its retention horizon' USING ERRCODE = '23514';
  END IF;
  SELECT count(*) INTO payload_count FROM @schema@.ash_onetime_response_payloads
  WHERE logical_partition = OLD.logical_partition AND partition_date = OLD.response_partition AND claim_id = OLD.id;
  IF payload_count <> 1 THEN
    RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE = '23514';
  END IF;
  DELETE FROM @schema@.ash_onetime_response_payloads
  WHERE logical_partition = OLD.logical_partition AND partition_date = OLD.response_partition AND claim_id = OLD.id;
  GET DIAGNOSTICS payload_count = ROW_COUNT;
  IF payload_count <> 1 THEN
    RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END
