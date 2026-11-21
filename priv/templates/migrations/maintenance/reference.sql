DECLARE
  reference_prefix text := 'aor_' || pg_backend_pid() || '_';
  roots text[] := ARRAY['ash_onetime_idempotency_claims','ash_onetime_nonce_claims',
    'ash_onetime_response_payloads','ash_onetime_maintenance_runs','ash_onetime_effect_outcomes','ash_onetime_external_state_restore'];
  ddl text;
  statement text;
  root text;
  child record;
  hash_claims boolean := (SELECT relkind='p' FROM pg_class WHERE oid=@idempotency@::regclass);
  relation_oid oid;
  reference_name text;
  reference_claims text;
  result jsonb := jsonb_build_object('server_version_num',current_setting('server_version_num'));
  sample_bytes integer[];
  primary_definition text;
  -- rule:reference-graph-complete
  capture_after_graph boolean := true;
BEGIN
  reference_claims := format('%I.%I',@schema_name@,replace('ash_onetime_idempotency_claims','ash_onetime_',reference_prefix));
  -- Build both sides and all their partitions before capturing either side.
  FOREACH root IN ARRAY roots LOOP
    ddl := CASE root || CASE WHEN hash_claims AND root IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims') THEN '_hash' ELSE '' END
      @reference_ddl@
    END;
    IF root='ash_onetime_effect_outcomes' THEN
      ddl := replace(replace(replace(ddl,
        '@hash_columns@',CASE WHEN hash_claims THEN 'operation_hash bytea NOT NULL, logical_partition text NOT NULL,' ELSE '' END),
        '@key_columns@',CASE WHEN hash_claims THEN 'operation_hash, logical_partition, ' ELSE '' END),
        '@partitioning@',CASE WHEN hash_claims THEN 'PARTITION BY HASH (operation_hash)' ELSE 'USING heap' END);
    END IF;
    FOREACH statement IN ARRAY string_to_array(ddl,';') LOOP
      CONTINUE WHEN btrim(statement)='';
      EXECUTE replace(replace(statement,'ash_onetime_',reference_prefix),'__package_schema__',format('%I',@schema_name@));
    END LOOP;
    reference_name := replace(root,'ash_onetime_',reference_prefix);
    relation_oid := format('%I.%I',@schema_name@,reference_name)::regclass;
    IF hash_claims AND root IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_effect_outcomes') THEN
      FOR child IN SELECT c.relpartbound, row_number() OVER (ORDER BY c.oid) AS position
        FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent=@idempotency@::regclass LOOP
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES WITH (MODULUS %s, REMAINDER %s) USING heap',
          @schema_name@,reference_name || '_p' || child.position,relation_oid::regclass,
          (regexp_match(child.relpartbound::text,':modulus ([0-9]+)'))[1]::integer,
          (regexp_match(child.relpartbound::text,':remainder ([0-9]+)'))[1]::integer);
      END LOOP;
    ELSIF root='ash_onetime_response_payloads' THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s DEFAULT USING heap',@schema_name@,reference_name || '_default',relation_oid::regclass);
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (''2000-01-01'') TO (''2000-02-01'') USING heap',@schema_name@,reference_name || '_month',relation_oid::regclass);
    END IF;
    IF root IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims') THEN
      EXECUTE format('CREATE TRIGGER %I BEFORE DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I.%I()',
        CASE root WHEN 'ash_onetime_idempotency_claims' THEN 'ash_onetime_idempotency_delete_guard' ELSE 'ash_onetime_nonce_delete_guard' END,
        relation_oid::regclass,@routine_schema_name@,
        CASE root WHEN 'ash_onetime_idempotency_claims' THEN 'ash_onetime_guard_idempotency_delete' ELSE 'ash_onetime_guard_nonce_delete' END);
      -- rule:reference-always-delete
      EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I',relation_oid::regclass,
        CASE root WHEN 'ash_onetime_idempotency_claims' THEN 'ash_onetime_idempotency_delete_guard' ELSE 'ash_onetime_nonce_delete_guard' END);
    END IF;
    IF root='ash_onetime_idempotency_claims' THEN
      EXECUTE format('CREATE TRIGGER ash_onetime_idempotency_update_guard BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_idempotency_update()',relation_oid::regclass,@routine_schema_name@);
      -- rule:reference-always-claim-update
      EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER ash_onetime_idempotency_update_guard',relation_oid::regclass);
    ELSIF root='ash_onetime_effect_outcomes' THEN
      EXECUTE format('CREATE TRIGGER ash_onetime_effect_outcome_guard BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_effect_outcome()',relation_oid::regclass,@routine_schema_name@);
      -- rule:reference-always-outcome-guard
      EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_guard',relation_oid::regclass);
      EXECUTE format('CREATE TRIGGER ash_onetime_effect_outcome_bound BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_bound_effect_outcome()',relation_oid::regclass,@routine_schema_name@);
      -- rule:reference-always-outcome-bound
      EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_bound',relation_oid::regclass);
    END IF;
    IF NOT capture_after_graph THEN
      result := result || jsonb_build_object(root,@routines@.ash_onetime_maintenance_shape(relation_oid));
    END IF;
  END LOOP;
  result := result || jsonb_build_object('package_roots',to_jsonb(roots));
  FOREACH root IN ARRAY roots LOOP
    reference_name := replace(root,'ash_onetime_',reference_prefix);
    relation_oid := format('%I.%I',@schema_name@,reference_name)::regclass;
    IF capture_after_graph THEN
      result := result || jsonb_build_object(root,@routines@.ash_onetime_maintenance_shape(relation_oid));
    END IF;
    IF hash_claims AND root IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_effect_outcomes') THEN
      result := result || jsonb_build_object(root || '_children',
        (SELECT jsonb_object_agg(regexp_replace(c.relpartbound::text,':location [-0-9]+',':location -1','g'),@routines@.ash_onetime_maintenance_shape(c.oid))
          FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent=relation_oid));
    END IF;
    SELECT i.inhrelid INTO child FROM pg_inherits i WHERE i.inhparent=relation_oid ORDER BY i.inhrelid LIMIT 1;
    IF FOUND THEN result := result || jsonb_build_object(root || '_child',@routines@.ash_onetime_maintenance_shape(child.inhrelid)); END IF;
  END LOOP;
  relation_oid := format('%I.%I',@schema_name@,reference_prefix || 'response_payloads_default')::regclass;
  result := result || jsonb_build_object('payload_default_bound',
    (SELECT regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g') FROM pg_class WHERE oid=relation_oid));
  relation_oid := format('%I.%I',@schema_name@,reference_prefix || 'response_payloads_month')::regclass;
  SELECT regexp_split_to_array(btrim(m[1]),'\s+')::integer[] INTO STRICT sample_bytes
    FROM pg_class c CROSS JOIN LATERAL regexp_matches(c.relpartbound::text,':constvalue 4 \[ ([0-9 -]+) \]','g') m
    WHERE c.oid=relation_oid OFFSET 1 LIMIT 1;
  -- rule:reference-date-encoding-refusal
  IF sample_bytes[1]<>31 AND sample_bytes[4]<>31 THEN RAISE EXCEPTION 'untrusted_dependency: unsupported date encoding'; END IF;
  result := result || jsonb_build_object('payload_byte_order',CASE WHEN sample_bytes[1]=31 THEN 'little' ELSE 'big' END,
    'payload_range_bound',(SELECT regexp_replace(regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g'),':constvalue 4 \[ [0-9 -]+ \]',':constvalue <date>','g') FROM pg_class WHERE oid=relation_oid));
  FOREACH root IN ARRAY roots LOOP
    EXECUTE format('DROP TABLE %I.%I CASCADE',@schema_name@,replace(root,'ash_onetime_',reference_prefix));
  END LOOP;
  RETURN result;
END
