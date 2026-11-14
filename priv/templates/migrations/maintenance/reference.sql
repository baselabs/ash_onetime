DECLARE
  reference_prefix text := 'aor_' || pg_backend_pid() || '_';
  ddl text;
  statement text;
  root record;
  child record;
  check_definitions jsonb;
  sample_bytes integer[];
  relation_oid oid;
  result jsonb := jsonb_build_object('server_version_num',current_setting('server_version_num'));
  reference_name text;
BEGIN
  -- These statements are extracted from the same package DDL as a fresh install.
  -- No catalog expression is deparsed or adopted to build the reference.
  FOR root IN SELECT * FROM (VALUES
    ('ash_onetime_idempotency_claims'),('ash_onetime_nonce_claims'),
    ('ash_onetime_response_payloads'),('ash_onetime_maintenance_runs')) r(name)
  LOOP
    ddl := CASE root.name
      @reference_ddl@
    END;
    IF root.name IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims')
      AND (SELECT relkind FROM pg_class WHERE oid=format('%I.%I',@schema_name@,root.name)::regclass)='p' THEN
      ddl := replace(replace(replace(ddl,'id uuid PRIMARY KEY','id uuid NOT NULL'),
        'UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)',
        'PRIMARY KEY (operation_hash, logical_partition, id), UNIQUE (logical_partition, operation_hash, scope_hash, key_hash)'),
        'USING heap;',
        'PARTITION BY HASH (operation_hash);');
    END IF;
    IF legacy_mode THEN
      ddl := replace(ddl,'octet_length(hold_reference) >= 1 AND octet_length(hold_reference) <= 255 AND state',
        'octet_length(hold_reference) BETWEEN 1 AND 255 AND state');
      ddl := replace(ddl,'octet_length(response_codec) >= 1 AND octet_length(response_codec) <= 128',
        'octet_length(response_codec) BETWEEN 1 AND 128');
    END IF;
    -- Semicolons delimit only package-authored DDL, not consumer input.
    FOREACH statement IN ARRAY string_to_array(ddl,';') LOOP
      CONTINUE WHEN btrim(statement)='';
      EXECUTE replace(replace(statement,'ash_onetime_',reference_prefix),'__package_schema__',format('%I',@schema_name@));
    END LOOP;
    reference_name := replace(root.name,'ash_onetime_',reference_prefix);
    relation_oid := format('%I.%I',@schema_name@,reference_name)::regclass;
    IF root.name IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims') THEN
      EXECUTE format('CREATE TRIGGER %I BEFORE DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I.%I()',
        CASE root.name WHEN 'ash_onetime_idempotency_claims' THEN 'ash_onetime_idempotency_delete_guard' ELSE 'ash_onetime_nonce_delete_guard' END,
        relation_oid::regclass,@routine_schema_name@,
        CASE root.name WHEN 'ash_onetime_idempotency_claims' THEN 'ash_onetime_guard_idempotency_delete' ELSE 'ash_onetime_guard_nonce_delete' END);
    END IF;
    result := result || jsonb_build_object(root.name,@routines@.ash_onetime_maintenance_shape(relation_oid::oid));
    -- This deparser sees only this routine's newly created package DDL. It
    -- supplies ALTER DDL after an exact legacy-tree comparison, never facts
    -- used to decide whether a consumer expression is trusted.
    SELECT jsonb_object_agg(replace(conname,reference_prefix,'ash_onetime_'),pg_get_constraintdef(oid))
      INTO check_definitions FROM pg_constraint WHERE conrelid=relation_oid AND contype='c';
    result := result || jsonb_build_object(root.name || '_check_ddl',coalesce(check_definitions,'{}'));
    IF root.name='ash_onetime_response_payloads' OR
      (root.name IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims') AND (SELECT relkind FROM pg_class WHERE oid=relation_oid)='p') THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s %s USING heap',@schema_name@,reference_name || '_child',relation_oid::regclass,
        CASE root.name WHEN 'ash_onetime_response_payloads' THEN 'DEFAULT' ELSE 'FOR VALUES WITH (MODULUS 2, REMAINDER 0)' END);
      result := result || jsonb_build_object(root.name || '_child',@routines@.ash_onetime_maintenance_shape(format('%I.%I',@schema_name@,reference_name || '_child')::regclass::oid));
      IF root.name='ash_onetime_response_payloads' THEN
        result := result || jsonb_build_object('payload_default_bound',
          (SELECT regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g') FROM pg_class WHERE oid=format('%I.%I',@schema_name@,reference_name || '_child')::regclass));
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (''2000-01-01'') TO (''2000-02-01'') USING heap',@schema_name@,reference_name || '_month',relation_oid::regclass);
        SELECT regexp_split_to_array(btrim(m[1]),'\s+')::integer[] INTO STRICT sample_bytes
          FROM pg_class c CROSS JOIN LATERAL regexp_matches(c.relpartbound::text,':constvalue 4 \[ ([0-9 -]+) \]','g') m
          WHERE c.oid=format('%I.%I',@schema_name@,reference_name || '_month')::regclass OFFSET 1 LIMIT 1;
        IF sample_bytes[1]<>31 AND sample_bytes[4]<>31 THEN
          RAISE EXCEPTION 'untrusted_dependency: unsupported date encoding';
        END IF;
        result := result || jsonb_build_object('payload_byte_order',CASE WHEN sample_bytes[1]=31 THEN 'little' ELSE 'big' END);
        result := result || jsonb_build_object('payload_range_bound',
          (SELECT regexp_replace(regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g'), ':constvalue 4 \[ [0-9 -]+ \]', ':constvalue <date>','g') FROM pg_class WHERE oid=format('%I.%I',@schema_name@,reference_name || '_month')::regclass));
      END IF;
    END IF;
  END LOOP;
  FOR root IN SELECT * FROM (VALUES
    ('ash_onetime_idempotency_claims'),('ash_onetime_nonce_claims'),
    ('ash_onetime_response_payloads'),('ash_onetime_maintenance_runs')) r(name)
  LOOP
    EXECUTE format('DROP TABLE %I.%I CASCADE',@schema_name@,replace(root.name,'ash_onetime_',reference_prefix));
  END LOOP;
  RETURN result;
END
