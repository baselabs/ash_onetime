BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'unsupported_isolation: maintenance requires READ COMMITTED' USING ERRCODE = '25001';
  END IF;
  PERFORM set_config('lock_timeout', least(5000, greatest(1, budget_ms))::text, true);
  LOCK TABLE @schema@.ash_onetime_idempotency_claims IN ROW EXCLUSIVE MODE;
  LOCK TABLE @schema@.ash_onetime_nonce_claims IN ROW EXCLUSIVE MODE;
  IF exclusive_parent THEN
    LOCK TABLE ONLY @schema@.ash_onetime_response_payloads IN ACCESS EXCLUSIVE MODE;
    -- The trust check includes every child. Block trigger DDL on them too;
    -- ordinary readers do not prevent this lock from being acquired.
    LOCK TABLE @schema@.ash_onetime_response_payloads IN ROW EXCLUSIVE MODE;
  ELSE
    LOCK TABLE @schema@.ash_onetime_response_payloads IN ROW EXCLUSIVE MODE;
  END IF;
  LOCK TABLE @schema@.ash_onetime_maintenance_runs IN ROW EXCLUSIVE MODE;
  IF (SELECT relowner FROM pg_class WHERE oid=@payload@::regclass)<>@owner@ THEN
    RAISE EXCEPTION 'maintenance_blinded: payload parent owner changed';
  END IF;
END
