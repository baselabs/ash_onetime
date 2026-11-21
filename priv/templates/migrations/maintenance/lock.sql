DECLARE
  deadline timestamptz := clock_timestamp() + budget_ms * interval '1 millisecond';
  roots text[] := ARRAY['ash_onetime_idempotency_claims','ash_onetime_effect_outcomes','ash_onetime_nonce_claims',
    'ash_onetime_response_payloads','ash_onetime_maintenance_runs','ash_onetime_external_state_restore'];
  root text;
  lock_index integer;
  remaining integer;
BEGIN
  -- rule:rls-isolation-precondition
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'unsupported_isolation: maintenance requires READ COMMITTED' USING ERRCODE = '25001';
  END IF;
  -- Every step shares this order. Recursion closes inheritance DDL races on
  -- claims and runs as well as partition attachment and trigger DDL races.
  FOR lock_index IN 1..(cardinality(roots) + CASE WHEN exclusive_parent THEN 1 ELSE 0 END) LOOP
    remaining := floor(extract(epoch FROM (deadline-clock_timestamp()))*1000)::integer;
    -- rule:lock-root-budget-refusal
    IF remaining<=0 THEN RAISE EXCEPTION 'maintenance lock budget exhausted' USING ERRCODE='55P03'; END IF; -- root lock budget
    PERFORM set_config('lock_timeout',least(5000,remaining)::text,true);
    IF lock_index <= cardinality(roots) THEN
      root := roots[lock_index];
      -- rule:maintenance-recursive-lock
      EXECUTE format('LOCK TABLE %I.%I IN SHARE UPDATE EXCLUSIVE MODE',@schema_name@,root);
    ELSE
      LOCK TABLE ONLY @schema@.ash_onetime_response_payloads IN ACCESS EXCLUSIVE MODE;
    END IF;
  END LOOP;
  IF (SELECT relowner FROM pg_class WHERE oid=@payload@::regclass)<>@owner@ THEN
    -- rule:lock-parent-owner-refusal
    RAISE EXCEPTION 'untrusted_dependency: payload parent owner changed';
  END IF;
END
