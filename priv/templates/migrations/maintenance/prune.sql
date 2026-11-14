DECLARE
  candidate record;
  parent_oid oid := @payload@::regclass;
  default_oid oid;
  child_name text;
  facts record;
  bounds text[];
  occupied boolean;
  deadline timestamptz;
  remaining integer;
  dropped integer := 0;
  kept integer := 0;
  refusals jsonb := '{}';
  reason text;
  previous_timeout text := current_setting('lock_timeout');
  previous_rls text := current_setting('row_security');
  previous_setting text := current_setting('ash_onetime.maintenance',true);
  report jsonb;
BEGIN
  IF partition_limit IS NULL OR partition_limit < 1 OR partition_limit > 128
    OR lock_budget_ms IS NULL OR lock_budget_ms < 1 OR lock_budget_ms > 5000 THEN
    RAISE EXCEPTION 'invalid prune bounds' USING ERRCODE='22023';
  END IF;
  PERFORM @schema@.ash_onetime_maintenance_lock(false,lock_budget_ms);
  PERFORM @schema@.ash_onetime_maintenance_trust();
  deadline := clock_timestamp() + lock_budget_ms * interval '1 millisecond';
  PERFORM set_config('ash_onetime.maintenance','on',true);
  SELECT partdefid INTO default_oid FROM pg_partitioned_table WHERE partrelid=parent_oid;

  FOR candidate IN
    SELECT c.oid,c.relname,n.nspname,pg_get_expr(c.relpartbound,c.oid) AS boundary
    FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE i.inhparent=parent_oid AND c.oid<>coalesce(default_oid,0)
      AND pg_get_expr(c.relpartbound,c.oid)<>'DEFAULT'
    ORDER BY pg_get_expr(c.relpartbound,c.oid),c.oid
  LOOP
    bounds := regexp_match(candidate.boundary, '^FOR VALUES FROM [(]''([0-9]{4}-[0-9]{2}-[0-9]{2})''[)] TO [(]''([0-9]{4}-[0-9]{2}-[0-9]{2})''[)]$');
    IF bounds IS NULL THEN RAISE EXCEPTION 'untrusted_dependency: partition bound %',candidate.relname; END IF;
    CONTINUE WHEN transaction_timestamp()::date <= bounds[2]::date;
    EXIT WHEN dropped+kept >= partition_limit;
    remaining := floor(extract(epoch FROM (deadline-clock_timestamp()))*1000)::integer;
    EXIT WHEN remaining<=0;
    child_name := format('%I.%I',candidate.nspname,candidate.relname);
    reason := NULL;
    BEGIN
      SELECT c.relkind,c.relowner,EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=parent_oid) AS child
      INTO facts FROM pg_class c WHERE c.oid=candidate.oid;
      IF NOT FOUND THEN RAISE EXCEPTION 'missing' USING ERRCODE='AOP01'; END IF;
      IF facts.relkind<>'r' OR NOT facts.child THEN RAISE EXCEPTION 'not_plain_child' USING ERRCODE='AOP01'; END IF;
      IF facts.relowner<>@owner@ THEN RAISE EXCEPTION 'not_owner' USING ERRCODE='AOP01'; END IF;
      IF NOT pg_try_advisory_xact_lock(1095716946,parent_oid::integer) THEN
        RAISE EXCEPTION 'pruner_busy' USING ERRCODE='AOP01';
      END IF;
      PERFORM set_config('lock_timeout',remaining::text,true);
      PERFORM set_config('row_security','off',true);
      LOCK TABLE ONLY @schema@.ash_onetime_response_payloads IN ACCESS EXCLUSIVE MODE;
      EXECUTE format('LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE NOWAIT',child_name);
      IF default_oid<>0 THEN
        EXECUTE format('LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE NOWAIT',default_oid::regclass);
      END IF;
      SELECT c.relkind,c.relowner,EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=parent_oid) AS child
      INTO facts FROM pg_class c WHERE c.oid=candidate.oid;
      IF NOT FOUND THEN RAISE EXCEPTION 'missing' USING ERRCODE='AOP01'; END IF;
      IF facts.relkind<>'r' OR NOT facts.child THEN RAISE EXCEPTION 'not_plain_child' USING ERRCODE='AOP01'; END IF;
      IF facts.relowner<>@owner@ THEN RAISE EXCEPTION 'not_owner' USING ERRCODE='AOP01'; END IF;
      EXECUTE format('ALTER TABLE %s NO FORCE ROW LEVEL SECURITY',child_name);
      IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=candidate.oid) THEN
        RAISE EXCEPTION 'force_reapplied' USING ERRCODE='AOP01';
      END IF;
      EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s)',child_name) INTO occupied;
      IF occupied THEN RAISE EXCEPTION 'occupied' USING ERRCODE='AOP01'; END IF;
      EXECUTE format('DROP TABLE %s',child_name);
      dropped := dropped+1;
    EXCEPTION
      WHEN SQLSTATE 'AOP01' THEN GET STACKED DIAGNOSTICS reason=MESSAGE_TEXT;
      WHEN lock_not_available THEN reason := 'lock_unavailable';
      WHEN OTHERS THEN reason := 'ddl_blocked';
    END;
    EXIT WHEN reason='pruner_busy';
    IF reason IS NOT NULL THEN
      kept := kept+1;
      IF reason<>'occupied' THEN
        refusals := jsonb_set(refusals,ARRAY[reason],to_jsonb(coalesce((refusals->>reason)::integer,0)+1));
      END IF;
    END IF;
    PERFORM set_config('row_security',previous_rls,true);
  END LOOP;
  report := jsonb_build_object('dropped',dropped,'kept',kept,'refusals',refusals,
    'blocked', EXISTS(SELECT 1 FROM jsonb_object_keys(refusals) k WHERE k<>'lock_unavailable'));
  INSERT INTO @schema@.ash_onetime_maintenance_runs(step,last_success_at,last_counts,last_refusals,updated_at)
  VALUES ('prune',clock_timestamp(),report,refusals,clock_timestamp())
  ON CONFLICT(step) DO UPDATE SET last_success_at=EXCLUDED.last_success_at,
    last_counts=EXCLUDED.last_counts,last_refusals=EXCLUDED.last_refusals,updated_at=EXCLUDED.updated_at;
  PERFORM set_config('ash_onetime.maintenance',coalesce(previous_setting,''),true);
  PERFORM set_config('row_security',previous_rls,true);
  PERFORM set_config('lock_timeout',previous_timeout,true);
  RETURN report;
END
