DECLARE
  previous_setting text := current_setting('ash_onetime.maintenance',true);
  previous_timeout text := current_setting('lock_timeout');
  checks jsonb;
  policy_error text;
  trust_error text;
  steps jsonb;
  installed timestamptz;
  cleanup_age bigint;
  reap_age bigint;
  held_count bigint;
  held_age bigint;
  default_rows boolean;
  default_oid oid;
  coverage_until date := date_trunc('month',transaction_timestamp())::date;
  part record;
  bounds text[];
  prune_refusals jsonb;
  manifest jsonb;
  definitions_ok boolean;
BEGIN
  IF (SELECT relowner FROM pg_class WHERE oid=@payload@::regclass)<>@owner@ THEN
    RETURN jsonb_build_object('checks',jsonb_build_object('policy',false,'acl',false,'trust',false,'definers',false),
      'trust_error','payload parent owner changed');
  END IF;
  PERFORM @routines@.ash_onetime_maintenance_lock(false::boolean,5000::integer);
  policy_error := @routines@.ash_onetime_maintenance_policy_error();
  BEGIN
    PERFORM @routines@.ash_onetime_maintenance_trust();
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS trust_error=MESSAGE_TEXT;
  END;
  IF trust_error IS NOT NULL THEN
    PERFORM set_config('lock_timeout',previous_timeout,true);
    RETURN jsonb_build_object('checks',jsonb_build_object('policy',policy_error IS NULL,'acl',false,'trust',false,'definers',false),
      'policy_error',policy_error,'trust_error',trust_error);
  END IF;
  SELECT installed_at,last_counts->'routines' INTO installed,manifest
  FROM @schema@.ash_onetime_maintenance_runs WHERE step='install';
  SELECT jsonb_object_agg(step,jsonb_build_object('last_success_at',last_success_at,
    'installed_at',installed,'last_counts',last_counts,'last_refusals',last_refusals,'updated_at',updated_at))
  INTO steps FROM @schema@.ash_onetime_maintenance_runs WHERE step<>'install';
  SELECT NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(manifest) m
    LEFT JOIN pg_namespace n ON n.nspname=m->>'schema'
    LEFT JOIN pg_proc p ON p.pronamespace=n.oid AND p.proname=m->>'name' AND p.proargtypes::text=m->>'arguments'
    WHERE p.oid IS NULL OR p.proowner<>(SELECT relowner FROM pg_class WHERE oid=@payload@::regclass) OR p.prosecdef IS DISTINCT FROM (m->>'definer')::boolean
      OR to_jsonb(p.proconfig) IS DISTINCT FROM m->'config'
      OR encode(sha256(convert_to(p.prosrc,'UTF8')),'hex') IS DISTINCT FROM m->>'digest'
      OR (to_jsonb(p)-ARRAY['oid','pronamespace','proowner','proacl','prosrc','prosupport','proargdefaults','prosqlbody','pronargdefaults']) IS DISTINCT FROM m->'identity'
      OR p.prosupport<>0
      OR jsonb_build_object('support',p.prosupport,'default_count',p.pronargdefaults,'defaults',@routines@.ash_onetime_maintenance_normalize(p.proargdefaults::text,0::oid),'sqlbody',@routines@.ash_onetime_maintenance_normalize(p.prosqlbody::text,0::oid)) IS DISTINCT FROM m->'executable'
  ) INTO definitions_ok;
  checks := jsonb_build_object('policy',policy_error IS NULL,'acl',@routines@.ash_onetime_maintenance_acl(),
    'trust',trust_error IS NULL,'definers',definitions_ok);
  SELECT coalesce(last_refusals,'{}') INTO prune_refusals FROM @schema@.ash_onetime_maintenance_runs WHERE step='prune';
  checks := checks || jsonb_build_object('prune',NOT EXISTS(SELECT 1 FROM jsonb_object_keys(coalesce(prune_refusals,'{}')) k WHERE k<>'lock_unavailable'));
  -- Read application rows only after establishing that no owner-executed
  -- expression can be supplied by a consumer, and that RLS is not blinding us.
  IF policy_error IS NULL AND trust_error IS NULL AND definitions_ok THEN
    PERFORM set_config('ash_onetime.maintenance','on',true);
    SELECT extract(epoch FROM (transaction_timestamp()-min(retain_until)))::bigint INTO cleanup_age FROM (
      SELECT retain_until FROM @schema@.ash_onetime_idempotency_claims
      WHERE state='complete' AND hold_reference IS NULL AND retain_until<transaction_timestamp()
      UNION ALL
      SELECT retain_until FROM @schema@.ash_onetime_nonce_claims WHERE retain_until<transaction_timestamp()
    ) backlog;
    SELECT extract(epoch FROM (transaction_timestamp()-min(inserted_at)))::bigint INTO reap_age
    FROM @schema@.ash_onetime_idempotency_claims WHERE state='processing'
      AND inserted_at<transaction_timestamp()-interval '86400 seconds' AND retain_until<transaction_timestamp();
    SELECT count(*),extract(epoch FROM (transaction_timestamp()-min(admitted_at)))::bigint INTO held_count,held_age
    FROM @schema@.ash_onetime_idempotency_claims WHERE hold_reference IS NOT NULL;
    SELECT partdefid INTO default_oid FROM pg_partitioned_table WHERE partrelid=@payload@::regclass;
    IF default_oid<>0 THEN EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)',default_oid::regclass) INTO default_rows;
    ELSE default_rows := false;
    END IF;
  END IF;
  FOR part IN SELECT pg_get_expr(c.relpartbound,c.oid) AS boundary
    FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid
    WHERE i.inhparent=@payload@::regclass AND c.oid<>coalesce(default_oid,0)
    ORDER BY pg_get_expr(c.relpartbound,c.oid)
  LOOP
    bounds := regexp_match(part.boundary,'^FOR VALUES FROM [(]''([0-9]{4}-[0-9]{2}-[0-9]{2})''[)] TO [(]''([0-9]{4}-[0-9]{2}-[0-9]{2})''[)]$');
    IF bounds IS NOT NULL AND bounds[1]::date<=coverage_until AND bounds[2]::date>coverage_until THEN
      coverage_until := bounds[2]::date;
    END IF;
  END LOOP;
  PERFORM set_config('ash_onetime.maintenance',coalesce(previous_setting,''),true);
  PERFORM set_config('lock_timeout',previous_timeout,true);
  RETURN jsonb_build_object('table_schema',@schema_name@,'routine_schema',@routine_schema_name@,'installed_at',installed,'steps',steps,'checks',checks,
    'policy_error',policy_error,'trust_error',trust_error,'oldest_cleanup_age_seconds',cleanup_age,
    'oldest_reapable_age_seconds',reap_age,'coverage_until',coverage_until,'default_has_rows',default_rows,
    'permanent_prune_refusals',coalesce(prune_refusals,'{}')-'lock_unavailable',
    'held_backlog',jsonb_build_object('held_count',held_count,'oldest_age_seconds',held_age));
END
