DECLARE
  reaped_count bigint;
  reap_before timestamptz;
  previous_setting text := current_setting('ash_onetime.maintenance', true);
  previous_reap text := current_setting('ash_onetime.reap_before', true);
  previous_timeout text := current_setting('lock_timeout');
  policy_error text;
BEGIN
  IF batch_size IS NULL OR batch_size < 1 OR batch_size > 10000 THEN
    RAISE EXCEPTION 'invalid reap batch size' USING ERRCODE = '22023';
  END IF;
  IF abandonment_seconds IS NULL OR abandonment_seconds < 86400 OR abandonment_seconds > 315576000000 THEN
    RAISE EXCEPTION 'invalid reap abandonment horizon (86400..315576000000 seconds)' USING ERRCODE = '22023';
  END IF;
  PERFORM @routines@.ash_onetime_maintenance_lock(false::boolean, 5000::integer);
  PERFORM @routines@.ash_onetime_maintenance_trust();
  PERFORM set_config('ash_onetime.maintenance', 'on', true);
  BEGIN
    reap_before := transaction_timestamp() - (abandonment_seconds * interval '1 second');
  EXCEPTION WHEN datetime_field_overflow THEN
    -- The accepted horizon can reach before PostgreSQL's finite timestamp
    -- range. No finite claim is old enough; retain it rather than underflow.
    reap_before := '-infinity'::timestamptz;
  END;
  PERFORM set_config('ash_onetime.reap_before', reap_before::text, true);
  WITH candidates AS (
    SELECT logical_partition,operation_hash,id FROM @schema@.ash_onetime_idempotency_claims
    WHERE state='processing' AND inserted_at < reap_before
      AND @routines@.ash_onetime_cleanup_eligible(retain_until::timestamptz)
    ORDER BY inserted_at,logical_partition,operation_hash,id
    FOR UPDATE SKIP LOCKED LIMIT batch_size
  ), deleted AS (
    DELETE FROM @schema@.ash_onetime_idempotency_claims claims USING candidates
    WHERE claims.logical_partition=candidates.logical_partition
      AND claims.operation_hash=candidates.operation_hash AND claims.id=candidates.id
    RETURNING claims.id
  ) SELECT count(*) INTO reaped_count FROM deleted;
  INSERT INTO @schema@.ash_onetime_maintenance_runs(step,last_success_at,last_counts,last_refusals,updated_at)
  VALUES ('reap',clock_timestamp(),jsonb_build_object('idempotency',reaped_count),'{}',clock_timestamp())
  ON CONFLICT(step) DO UPDATE SET last_success_at=EXCLUDED.last_success_at,
    last_counts=EXCLUDED.last_counts,last_refusals=EXCLUDED.last_refusals,updated_at=EXCLUDED.updated_at;
  PERFORM set_config('ash_onetime.reap_before',coalesce(previous_reap,''),true);
  PERFORM set_config('ash_onetime.maintenance',coalesce(previous_setting,''),true);
  PERFORM set_config('lock_timeout',previous_timeout,true);
  RETURN reaped_count;
END
