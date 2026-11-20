DECLARE
  expired_count bigint := 0;
  payload_count bigint;
  claim record;
  previous_setting text := current_setting('ash_onetime.maintenance',true);
BEGIN
  IF batch_size IS NULL OR batch_size<1 OR batch_size>10000 THEN
    -- rule:expire-arguments
    RAISE EXCEPTION 'invalid expiry batch size' USING ERRCODE='22023';
  END IF;
<%= if maintenance do %>
  PERFORM @routines@.ash_onetime_maintenance_lock(false::boolean,5000::integer);
  PERFORM @routines@.ash_onetime_maintenance_trust();
<% end %>
  PERFORM set_config('ash_onetime.maintenance','on',true);
  FOR claim IN SELECT logical_partition,operation_hash,id,response_partition
    FROM @schema@.ash_onetime_idempotency_claims
    WHERE state='complete' AND response_expired_at IS NULL
      -- rule:expire-skips-held
      AND hold_reference IS NULL
      -- rule:expire-selects-eligible
      AND @routines@.ash_onetime_cleanup_eligible(response_retain_until::timestamptz)
    ORDER BY response_retain_until,logical_partition,operation_hash,id
    -- rule:expire-lock-mode
    FOR NO KEY UPDATE SKIP LOCKED LIMIT batch_size
  LOOP
    DELETE FROM @schema@.ash_onetime_response_payloads
      WHERE logical_partition=claim.logical_partition AND partition_date=claim.response_partition AND claim_id=claim.id;
    GET DIAGNOSTICS payload_count = ROW_COUNT;
    -- rule:expire-payload-cardinality
    IF payload_count<>1 THEN
      RAISE EXCEPTION 'completed idempotency claim payload cardinality mismatch' USING ERRCODE='23514';
    END IF;
    UPDATE @schema@.ash_onetime_idempotency_claims SET response_partition=NULL,response_codec=NULL,
      response_digest=NULL,response_expired_at=transaction_timestamp()
      WHERE logical_partition=claim.logical_partition AND operation_hash=claim.operation_hash AND id=claim.id;
    expired_count := expired_count+1;
  END LOOP;
<%= if maintenance do %>
  INSERT INTO @schema@.ash_onetime_maintenance_runs(step,last_success_at,last_counts,last_refusals,updated_at)
    VALUES ('cleanup',clock_timestamp(),jsonb_build_object('responses_expired',expired_count),'{}',clock_timestamp())
    ON CONFLICT(step) DO UPDATE SET last_success_at=EXCLUDED.last_success_at,
      last_counts=ash_onetime_maintenance_runs.last_counts || EXCLUDED.last_counts,
      last_refusals=EXCLUDED.last_refusals,updated_at=EXCLUDED.updated_at;
<% end %>
  PERFORM set_config('ash_onetime.maintenance',coalesce(previous_setting,''),true);
  RETURN expired_count;
END
