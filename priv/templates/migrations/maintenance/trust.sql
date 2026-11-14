DECLARE
  manifest jsonb := '[]'::jsonb; -- @routine_manifest@
  expected jsonb;
  actual jsonb;
  relation_row record;
  root_name text;
  bound text;
  normalized_bound text;
  key_name text;
  policy_error text;
  date_token record;
  date_bytes integer[];
  day_number bigint;
  bound_dates date[];
BEGIN
  -- R2: only exact package identities and definitions are trusted. A runtime
  -- overload is unrelated and cannot match these argument type identities.
  IF jsonb_array_length(manifest)=0 OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(manifest) m
    LEFT JOIN pg_namespace n ON n.nspname=m->>'schema'
    LEFT JOIN pg_proc p ON p.pronamespace=n.oid AND p.proname=m->>'name' AND p.proargtypes::text=m->>'arguments'
    WHERE p.oid IS NULL OR p.proowner IS DISTINCT FROM (m->>'owner')::oid
      OR p.prosecdef IS DISTINCT FROM (m->>'definer')::boolean
      OR to_jsonb(p.proconfig) IS DISTINCT FROM m->'config'
      OR (to_jsonb(p)-ARRAY['oid','pronamespace','proowner','proacl','prosrc','prosupport','proargdefaults','prosqlbody','pronargdefaults']) IS DISTINCT FROM m->'identity'
      OR encode(sha256(convert_to(p.prosrc,'UTF8')),'hex') IS DISTINCT FROM m->>'digest'
  ) THEN RAISE EXCEPTION 'untrusted_dependency: package routine digest'; END IF;
  -- R2c executable metadata. Verify support before invoking any normalizer.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(manifest) m
    JOIN pg_namespace n ON n.nspname=m->>'schema'
    JOIN pg_proc p ON p.pronamespace=n.oid AND p.proname=m->>'name' AND p.proargtypes::text=m->>'arguments'
    WHERE p.prosupport<>0) THEN
    RAISE EXCEPTION 'untrusted_dependency: routine support';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(manifest) m
    JOIN pg_namespace n ON n.nspname=m->>'schema'
    JOIN pg_proc p ON p.pronamespace=n.oid AND p.proname=m->>'name' AND p.proargtypes::text=m->>'arguments'
    WHERE jsonb_build_object('support',p.prosupport,'default_count',p.pronargdefaults,
      'defaults',@routines@.ash_onetime_maintenance_normalize(p.proargdefaults::text,0::oid),
      'sqlbody',@routines@.ash_onetime_maintenance_normalize(p.prosqlbody::text,0::oid)) IS DISTINCT FROM m->'executable') THEN
    RAISE EXCEPTION 'untrusted_dependency: routine executable trees';
  END IF;
  -- End R2c executable metadata.
  -- R2b uses the trusted-owner/server boundary. Scheduled roles cannot join it.
  IF EXISTS (WITH RECURSIVE scheduled(oid) AS (
    SELECT @maintenance@::oid WHERE @maintenance@<>@owner@
    UNION SELECT m.member FROM scheduled s JOIN pg_auth_members m ON m.roleid=s.oid WHERE m.member<>@owner@
  ) SELECT 1 FROM scheduled s JOIN pg_roles r ON r.oid=s.oid WHERE NOT r.rolsuper
    AND pg_has_role(r.oid,@owner@,'MEMBER')) THEN
    RAISE EXCEPTION 'untrusted_dependency: runtime or maintenance owner membership';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname=@routine_schema_name@ AND nspowner=@owner@)
    OR EXISTS (SELECT 1 FROM pg_roles r WHERE NOT r.rolsuper AND r.oid<>@owner@
      AND NOT pg_has_role(r.oid,@owner@,'USAGE')
      AND has_schema_privilege(r.oid,@routine_schema_name@,'CREATE')) THEN
    RAISE EXCEPTION 'untrusted_dependency: routine schema CREATE';
  END IF;
  expected := @routines@.ash_onetime_maintenance_shapes();
  -- R1e: publication membership is safe only without executable row filters.
  IF EXISTS (SELECT 1 FROM pg_publication_rel p
    WHERE p.prrelid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND p.prqual IS NOT NULL) THEN
    RAISE EXCEPTION 'untrusted_dependency: publication row filter';
  END IF;
  -- R1: catalog trees only; no deparser and no routine ownership allowlist.
  FOR relation_row IN
    SELECT c.*,p.relname AS parent_name,i.inhparent
    FROM @routines@.ash_onetime_maintenance_relations() r
    JOIN pg_class c ON c.oid=r
    LEFT JOIN pg_inherits i ON i.inhrelid=c.oid
    LEFT JOIN pg_class p ON p.oid=i.inhparent
    WHERE true -- R1 relation set
    ORDER BY c.oid
  LOOP
    root_name := CASE WHEN relation_row.inhparent IS NULL THEN relation_row.relname ELSE relation_row.parent_name END;
    IF root_name NOT IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims',
        'ash_onetime_response_payloads','ash_onetime_maintenance_runs') OR
      (relation_row.inhparent IS NOT NULL AND (NOT relation_row.relispartition OR
        (SELECT count(*) FROM pg_inherits WHERE inhrelid=relation_row.oid)<>1)) THEN
      RAISE EXCEPTION 'untrusted_dependency: relation set';
    END IF;
    key_name := root_name || CASE WHEN relation_row.inhparent IS NULL THEN '' ELSE '_child' END;
    actual := @routines@.ash_onetime_maintenance_shape(relation_row.oid::oid);
    IF actual IS DISTINCT FROM expected->key_name THEN
      RAISE EXCEPTION 'untrusted_dependency: relation shape %',relation_row.relname;
    END IF;
    IF relation_row.relispartition THEN
      bound := regexp_replace(relation_row.relpartbound::text, ':location [-0-9]+', ':location -1','g');
      IF root_name='ash_onetime_response_payloads' THEN
        normalized_bound := regexp_replace(bound, ':constvalue 4 \[ [0-9 -]+ \]', ':constvalue <date>', 'g');
        IF normalized_bound IS DISTINCT FROM expected->>'payload_range_bound' AND
          bound IS DISTINCT FROM expected->>'payload_default_bound' THEN
          RAISE EXCEPTION 'untrusted_dependency: partition bound %',relation_row.relname;
        END IF;
        IF bound IS DISTINCT FROM expected->>'payload_default_bound' THEN
          bound_dates := '{}';
          BEGIN
            FOR date_token IN SELECT m FROM regexp_matches(bound,':constvalue 4 \[ ([0-9 -]+) \]','g') m LOOP
              date_bytes := regexp_split_to_array(btrim(date_token.m[1]),'\s+')::integer[];
              IF expected->>'payload_byte_order'='big' THEN
                date_bytes := ARRAY[date_bytes[4],date_bytes[3],date_bytes[2],date_bytes[1]];
              END IF;
              day_number := mod(date_bytes[1]+256,256)::bigint + mod(date_bytes[2]+256,256)*256::bigint
                + mod(date_bytes[3]+256,256)*65536::bigint + mod(date_bytes[4]+256,256)*16777216::bigint;
              IF day_number>2147483647 THEN day_number := day_number-4294967296; END IF;
              bound_dates := array_append(bound_dates,date '2000-01-01'+day_number::integer);
            END LOOP;
            IF cardinality(bound_dates)<>2 OR bound_dates[2]<=bound_dates[1] THEN
              RAISE EXCEPTION 'untrusted_dependency: invalid partition range';
            END IF;
          EXCEPTION WHEN datetime_field_overflow OR numeric_value_out_of_range THEN
            RAISE EXCEPTION 'untrusted_dependency: partition date range';
          END;
        END IF;
      ELSIF bound !~ '^\{PARTITIONBOUNDSPEC :strategy h :is_default false :modulus (2|4|8|16|32|64) :remainder [0-9]+ :listdatums <> :lowerdatums <> :upperdatums <> :location -1\}$' THEN
        RAISE EXCEPTION 'untrusted_dependency: hash partition bound';
      END IF;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_class c WHERE c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=@schema_name@)
    AND c.relname IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_response_payloads','ash_onetime_maintenance_runs'))<>4 THEN
    RAISE EXCEPTION 'untrusted_dependency: missing package root';
  END IF;
  -- The policy refusal has its own closed error, including Table 1 row 5.
  policy_error := @routines@.ash_onetime_maintenance_policy_error();
  IF policy_error IS NOT NULL THEN RAISE EXCEPTION 'maintenance_blinded: %',policy_error; END IF;
  -- R3a: inherited privileges and SET-reachable MAINTAIN holders. Owners are
  -- trusted; every other role that can maintain a relation is refused. Holders
  -- are found once, so the cost is roles x relations plus candidates x holders,
  -- and holders is empty on a trusted install.
  IF EXISTS (WITH RECURSIVE scheduled(oid) AS (
    SELECT @maintenance@::oid WHERE @maintenance@<>@owner@
    UNION SELECT m.member FROM scheduled s JOIN pg_auth_members m ON m.roleid=s.oid WHERE m.member<>@owner@
  ), relations AS MATERIALIZED (
    SELECT t::oid AS oid FROM @routines@.ash_onetime_maintenance_relations() t
  ), holders AS MATERIALIZED (
    SELECT holder.oid FROM pg_roles holder WHERE NOT holder.rolsuper AND holder.oid<>@owner@
      AND NOT pg_has_role(holder.oid,@owner@,'USAGE')
      AND EXISTS (SELECT 1 FROM relations t WHERE has_table_privilege(holder.oid,t.oid,'MAINTAIN'))
  ) SELECT 1 FROM pg_roles r JOIN holders holder
      ON (holder.oid=r.oid OR pg_has_role(r.oid,holder.oid,'SET'))
    WHERE (r.rolcanlogin OR r.oid IN (SELECT oid FROM scheduled)
      OR r.rolname=current_setting('role') OR r.rolname=session_user) AND NOT r.rolsuper AND r.oid<>@owner@ AND NOT pg_has_role(r.oid,@owner@,'USAGE')) THEN
    RAISE EXCEPTION 'untrusted_dependency: effective MAINTAIN privilege';
  END IF;

END
