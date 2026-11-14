DECLARE
  deadline timestamptz := clock_timestamp() + budget_ms * interval '1 millisecond';
  root text;
  remaining integer;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'unsupported_isolation: maintenance requires READ COMMITTED' USING ERRCODE = '25001';
  END IF;
  -- Every step shares this order. Recursion closes inheritance DDL races on
  -- claims and runs as well as partition attachment and trigger DDL races.
  FOREACH root IN ARRAY ARRAY['ash_onetime_idempotency_claims','ash_onetime_nonce_claims',
    'ash_onetime_response_payloads','ash_onetime_maintenance_runs'] LOOP
    remaining := floor(extract(epoch FROM (deadline-clock_timestamp()))*1000)::integer;
    IF remaining<=0 THEN RAISE EXCEPTION 'maintenance lock budget exhausted' USING ERRCODE='55P03'; END IF;
    PERFORM set_config('lock_timeout',least(5000,remaining)::text,true);
    EXECUTE format('LOCK TABLE %I.%I IN SHARE UPDATE EXCLUSIVE MODE',@schema_name@,root);
  END LOOP;
  IF exclusive_parent THEN
    remaining := floor(extract(epoch FROM (deadline-clock_timestamp()))*1000)::integer;
    IF remaining<=0 THEN RAISE EXCEPTION 'maintenance lock budget exhausted' USING ERRCODE='55P03'; END IF;
    PERFORM set_config('lock_timeout',least(5000,remaining)::text,true);
    LOCK TABLE ONLY @schema@.ash_onetime_response_payloads IN ACCESS EXCLUSIVE MODE;
  END IF;
  IF (SELECT relowner FROM pg_class WHERE oid=@payload@::regclass)<>@owner@ THEN
    RAISE EXCEPTION 'untrusted_dependency: payload parent owner changed';
  END IF;
END
