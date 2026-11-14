DECLARE
  parent_oid oid := @payload@::regclass;
  default_oid oid;
  default_forced boolean;
  default_enabled boolean;
  has_default_rows boolean := false;
  month_date date;
  until_date date;
  child_name text;
  child_oid oid;
  create_child text;
  created integer := 0;
  months date[] := '{}';
  previous_setting text := current_setting('ash_onetime.maintenance',true);
  previous_rls text := current_setting('row_security');
  previous_timeout text := current_setting('lock_timeout');
BEGIN
  IF months_ahead IS NULL OR months_ahead<1 OR months_ahead>24 THEN
    RAISE EXCEPTION 'invalid roll months (1..24)' USING ERRCODE='22023';
  END IF;
  PERFORM set_config('lock_timeout','5000',true);
  -- This two-int key is disjoint from prune's class and identifies the parent OID.
  PERFORM pg_advisory_xact_lock(1095717452,parent_oid::integer);
  PERFORM @routines@.ash_onetime_maintenance_lock(true::boolean,5000::integer);
  PERFORM @routines@.ash_onetime_maintenance_trust();
  PERFORM set_config('ash_onetime.maintenance','on',true);
  SELECT partdefid INTO default_oid FROM pg_partitioned_table WHERE partrelid=parent_oid;
  IF default_oid<>0 THEN
    EXECUTE format('LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE NOWAIT',default_oid::regclass);
    SELECT relrowsecurity,relforcerowsecurity INTO STRICT default_enabled,default_forced FROM pg_class WHERE oid=default_oid;
    EXECUTE format('ALTER TABLE %s NO FORCE ROW LEVEL SECURITY',default_oid::regclass);
    IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=default_oid) THEN
      RAISE EXCEPTION 'prune_blocked: FORCE reapplied to DEFAULT';
    END IF;
    PERFORM set_config('row_security','off',true);
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)',default_oid::regclass) INTO has_default_rows;
    IF has_default_rows THEN
      EXECUTE format('SELECT coalesce(array_agg(month_date ORDER BY month_date),''{}''::date[]) FROM (SELECT DISTINCT date_trunc(''month'',partition_date)::date AS month_date FROM %s ORDER BY 1 LIMIT 24) months',default_oid::regclass) INTO months;
    END IF;
    IF default_forced THEN EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',default_oid::regclass); END IF;
    PERFORM set_config('row_security',previous_rls,true);
  END IF;
  SELECT array_agg(m ORDER BY priority,m) INTO months FROM (
    SELECT m,min(priority) AS priority FROM (
      SELECT unnest(months) AS m,0 AS priority
      UNION ALL
      SELECT (date_trunc('month',transaction_timestamp())+i*interval '1 month')::date,1
      FROM generate_series(0,months_ahead-1) i
    ) all_months GROUP BY m
    ORDER BY min(priority),m LIMIT 24
  ) limited;
  FOREACH month_date IN ARRAY months LOOP
    until_date := (month_date+interval '1 month')::date;
    child_name := 'ash_onetime_response_payloads_' || to_char(month_date,'YYYY_MM');
    -- A name is accepted only if it is an actual child, never a standalone table.
    SELECT c.oid INTO child_oid FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid
    WHERE i.inhparent=parent_oid AND c.relnamespace=(SELECT relnamespace FROM pg_class WHERE oid=parent_oid)
      AND c.relname=child_name AND c.relkind='r'
      AND pg_get_expr(c.relpartbound,c.oid)=format('FOR VALUES FROM (%L) TO (%L)',month_date,until_date);
    CONTINUE WHEN FOUND;
    BEGIN
      IF default_oid<>0 THEN
        EXECUTE format('LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE NOWAIT',default_oid::regclass);
        SELECT relrowsecurity,relforcerowsecurity INTO STRICT default_enabled,default_forced FROM pg_class WHERE oid=default_oid;
        EXECUTE format('ALTER TABLE %s NO FORCE ROW LEVEL SECURITY',default_oid::regclass);
        IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=default_oid) THEN
          RAISE EXCEPTION 'prune_blocked: FORCE reapplied to DEFAULT';
        END IF;
        PERFORM set_config('row_security','off',true);
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE partition_date >= $1 AND partition_date < $2)',default_oid::regclass)
          INTO has_default_rows USING month_date,until_date;
      ELSE has_default_rows := false;
      END IF;
      IF has_default_rows THEN
        create_child := format('CREATE TABLE %I.%I (LIKE %I.ash_onetime_response_payloads INCLUDING ALL)',@schema_name@,child_name,@schema_name@);
      ELSE
        create_child := format('CREATE TABLE %I.%I PARTITION OF %I.ash_onetime_response_payloads FOR VALUES FROM (%L) TO (%L)',@schema_name@,child_name,@schema_name@,month_date,until_date);
      END IF;
      EXECUTE create_child || ' USING heap';
      child_oid := to_regclass(format('%I.%I',@schema_name@,child_name));
      PERFORM @routines@.ash_onetime_maintenance_reset_acl(child_oid::oid,true::boolean);
      IF has_default_rows THEN
        EXECUTE format('WITH moved AS (DELETE FROM %s WHERE partition_date >= $1 AND partition_date < $2 RETURNING *) INSERT INTO %I.%I SELECT * FROM moved',
          default_oid::regclass,@schema_name@,child_name) USING month_date,until_date;
        EXECUTE format('ALTER TABLE %I.ash_onetime_response_payloads ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)',@schema_name@,@schema_name@,child_name,month_date,until_date);
      END IF;
      PERFORM @routines@.ash_onetime_maintenance_copy_policy(child_oid::oid);
      IF default_oid<>0 AND default_forced THEN
        EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',default_oid::regclass);
      END IF;
      PERFORM set_config('row_security',previous_rls,true);
      created := created+1;
    EXCEPTION WHEN duplicate_table THEN
      RAISE EXCEPTION 'untrusted_dependency: name collision';
    WHEN OTHERS THEN
      -- The subtransaction restores moved rows, attachment, flags, policies,
      -- ACLs, and settings as one unit; the exception also aborts this call.
      RAISE;
    END;
  END LOOP;
  INSERT INTO @schema@.ash_onetime_maintenance_runs(step,last_success_at,last_counts,last_refusals,updated_at)
  VALUES ('roll',clock_timestamp(),jsonb_build_object('partitions_created',created),'{}',clock_timestamp())
  ON CONFLICT(step) DO UPDATE SET last_success_at=EXCLUDED.last_success_at,
    last_counts=EXCLUDED.last_counts,last_refusals=EXCLUDED.last_refusals,updated_at=EXCLUDED.updated_at;
  PERFORM set_config('ash_onetime.maintenance',coalesce(previous_setting,''),true);
  PERFORM set_config('row_security',previous_rls,true);
  PERFORM set_config('lock_timeout',previous_timeout,true);
  RETURN created;
END
