DECLARE
  result jsonb := jsonb_build_object('server_version_num',current_setting('server_version_num'));
  root text;
  relation_oid oid;
  child_oid oid;
  sample_name text;
  sample_tree text;
  sample_bytes integer[];
  sample_days bigint;
  little_days bigint;
  big_days bigint;
BEGIN
  FOREACH root IN ARRAY ARRAY['ash_onetime_idempotency_claims','ash_onetime_nonce_claims',
    'ash_onetime_response_payloads','ash_onetime_maintenance_runs'] LOOP
    relation_oid := format('%I.%I',@schema_name@,root)::regclass;
    result := result || jsonb_build_object(root,@routines@.ash_onetime_maintenance_shape(relation_oid::oid));
    SELECT inhrelid INTO child_oid FROM pg_inherits WHERE inhparent=relation_oid ORDER BY inhrelid LIMIT 1;
    IF FOUND THEN
      result := result || jsonb_build_object(root || '_child',@routines@.ash_onetime_maintenance_shape(child_oid::oid));
    END IF;
  END LOOP;
  SELECT c.oid INTO STRICT child_oid FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid
    WHERE i.inhparent=@payload@::regclass AND c.relpartbound::text LIKE '%:is_default true%';
  result := result || jsonb_build_object('payload_default_bound',
    (SELECT regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g') FROM pg_class WHERE oid=child_oid));
  SELECT c.oid,c.relname,c.relpartbound::text INTO STRICT child_oid,sample_name,sample_tree FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid
    WHERE i.inhparent=@payload@::regclass AND c.relpartbound::text LIKE '%:is_default false%' ORDER BY c.oid LIMIT 1;
  sample_days := to_date(substring(sample_name FROM '[0-9]{4}_[0-9]{2}$'),'YYYY_MM') - date '2000-01-01';
  sample_bytes := regexp_split_to_array(btrim((regexp_match(sample_tree,':constvalue 4 \[ ([0-9 -]+) \]'))[1]),'\s+')::integer[];
  little_days := mod(sample_bytes[1]+256,256)::bigint + mod(sample_bytes[2]+256,256)*256::bigint
    + mod(sample_bytes[3]+256,256)*65536::bigint + mod(sample_bytes[4]+256,256)*16777216::bigint;
  IF little_days>2147483647 THEN little_days := little_days-4294967296; END IF;
  big_days := mod(sample_bytes[4]+256,256)::bigint + mod(sample_bytes[3]+256,256)*256::bigint
    + mod(sample_bytes[2]+256,256)*65536::bigint + mod(sample_bytes[1]+256,256)*16777216::bigint;
  IF big_days>2147483647 THEN big_days := big_days-4294967296; END IF;
  IF little_days<>sample_days AND big_days<>sample_days THEN
    RAISE EXCEPTION 'untrusted_dependency: unsupported date encoding';
  END IF;
  result := result || jsonb_build_object('payload_byte_order',CASE WHEN little_days=sample_days THEN 'little' ELSE 'big' END);
  result := result || jsonb_build_object('payload_range_bound',
    (SELECT regexp_replace(regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g'), ':constvalue 4 \[ [0-9 -]+ \]', ':constvalue <date>','g') FROM pg_class WHERE oid=child_oid));
  RETURN result;
END
