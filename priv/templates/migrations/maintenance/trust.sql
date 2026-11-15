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
  authority_error text;
  ownership_error record;
  containment_object record;
  ownership_column name;
  object_owner oid;
  owner_name name;
  authority_owner oid;
  holder_name name;
  database_owner oid;
  accepted_owner boolean;
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
  -- Containment follows deletion dependencies to a fixpoint. Whole-object
  -- addresses include column dependencies. No OID cutoff: unpinned initdb
  -- objects (including plpgsql) and every containing schema are checked.
  FOR containment_object IN
  WITH RECURSIVE package_relations AS MATERIALIZED (
    SELECT @routines@.ash_onetime_maintenance_relations() AS oid
    UNION SELECT t.tgrelid FROM pg_trigger t
      WHERE t.tgfoid=to_regprocedure(format('%I.ash_onetime_fact_append_only()',@schema_name@))
  ), roots(classid,objid) AS (
    SELECT 'pg_class'::regclass,oid FROM package_relations
    UNION SELECT 'pg_class'::regclass,i.indexrelid FROM pg_index i JOIN package_relations r ON r.oid=i.indrelid
    UNION SELECT 'pg_constraint'::regclass,k.oid FROM pg_constraint k JOIN package_relations r ON r.oid=k.conrelid
    UNION SELECT 'pg_trigger'::regclass,t.oid FROM pg_trigger t JOIN package_relations r ON r.oid=t.tgrelid
    UNION SELECT 'pg_policy'::regclass,p.oid FROM pg_policy p JOIN package_relations r ON r.oid=p.polrelid AND p.polname='ash_onetime_maintenance'
    UNION SELECT 'pg_proc'::regclass,p.oid FROM jsonb_array_elements(manifest) m
      JOIN pg_namespace n ON n.nspname=m->>'schema'
      JOIN pg_proc p ON p.pronamespace=n.oid AND p.proname=m->>'name' AND p.proargtypes::text=m->>'arguments'
    UNION SELECT 'pg_namespace'::regclass,to_regnamespace(@routine_schema_name@)
  ), closure(classid,objid) AS (
    SELECT classid,objid FROM roots
    UNION
    SELECT next.classid,next.objid FROM closure c CROSS JOIN LATERAL (
      SELECT d.refclassid AS classid,d.refobjid AS objid FROM pg_depend d WHERE d.classid=c.classid AND d.objid=c.objid
      -- Internal parts may promote deletion to the containing object.
      UNION SELECT d.classid,d.objid FROM pg_depend d WHERE d.refclassid=c.classid AND d.refobjid=c.objid AND d.deptype='i'
      -- Extension members may promote deletion to their extension.
      UNION SELECT d.classid,d.objid FROM pg_depend d WHERE c.classid='pg_extension'::regclass AND d.refclassid=c.classid AND d.refobjid=c.objid AND d.deptype='e'
    ) next
  ), objects AS MATERIALIZED (
    SELECT c.classid,c.objid,i.schema,i.identity FROM closure c
    CROSS JOIN LATERAL pg_identify_object(c.classid,c.objid,0) i
  ) SELECT classid,objid,identity FROM objects
    UNION SELECT 'pg_namespace'::regclass,n.oid,'schema ' || quote_ident(n.nspname)
      FROM objects o JOIN pg_namespace n ON n.nspname=o.schema
    ORDER BY 1,2
  LOOP
    -- Read the catalog's ownership column, including pinned/bootstrap owners
    -- absent from pg_shdepend. Internal objects without an independent owner
    -- derive their authority from the containing object already in the walk.
    SELECT a.attname INTO ownership_column FROM pg_attribute a
      WHERE a.attrelid=containment_object.classid AND a.attname LIKE '%owner'
        AND a.atttypid='oid'::regtype AND NOT a.attisdropped;
    CONTINUE WHEN ownership_column IS NULL;
    EXECUTE format('SELECT %I FROM %s WHERE oid=$1',ownership_column,containment_object.classid::regclass)
      INTO object_owner USING containment_object.objid;
    SELECT r.rolname,db.datdba,
      CASE WHEN r.rolname='pg_database_owner' THEN db.datdba ELSE r.oid END,
      r.oid=@owner@ OR r.rolsuper OR (r.rolname='pg_database_owner' AND (db.datdba=@owner@ OR dbowner.rolsuper))
      INTO owner_name,database_owner,authority_owner,accepted_owner
    FROM pg_roles r CROSS JOIN pg_database db JOIN pg_roles dbowner ON dbowner.oid=db.datdba
    WHERE r.oid=object_owner AND db.datname=current_database();
    IF NOT accepted_owner THEN
      RAISE EXCEPTION 'untrusted_dependency: containment object %, owner %, database owner %',
        containment_object.identity,owner_name,pg_get_userbyid(database_owner);
    END IF;
    -- An accepted structural owner must not lend authority to an untrusted holder.
    IF object_owner<>@owner@ THEN
      SELECT r.rolname INTO holder_name FROM pg_roles r
      WHERE pg_has_role(r.oid,authority_owner,'MEMBER') AND NOT r.rolsuper
        AND NOT pg_has_role(r.oid,@owner@,'MEMBER') ORDER BY r.rolname LIMIT 1;
      IF FOUND THEN
        RAISE EXCEPTION 'untrusted_dependency: containment object %, owner %, authority owner %, holder %',
          containment_object.identity,owner_name,pg_get_userbyid(authority_owner),holder_name;
      END IF;
    END IF;
    -- End structural holder rule.
  END LOOP;
  -- End containment.

  IF EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    WHERE c.relnamespace=to_regnamespace(@schema_name@)
      AND t.tgfoid=to_regprocedure(format('%I.ash_onetime_fact_append_only()',@schema_name@)) AND t.tgenabled<>'A') THEN
    RAISE EXCEPTION 'untrusted_dependency: fact trigger firing mode';
  END IF;

  -- Event-trigger code runs under DDL and login identities, even outside the
  -- relation graph. Disabled triggers remain an authority held by their owner.
  SELECT e.evtname,p.oid::regprocedure AS function_name,r.rolname AS owner_name,
    holder.rolname AS holder INTO ownership_error
  FROM pg_event_trigger e JOIN pg_proc p ON p.oid=e.evtfoid JOIN pg_roles r ON r.oid=p.proowner
  CROSS JOIN pg_database db JOIN pg_roles dbowner ON dbowner.oid=db.datdba
  LEFT JOIN LATERAL (
    SELECT h.rolname FROM pg_roles h
    WHERE pg_has_role(h.oid,CASE WHEN r.rolname='pg_database_owner' THEN db.datdba ELSE r.oid END,'MEMBER')
      AND NOT h.rolsuper AND NOT pg_has_role(h.oid,@owner@,'MEMBER')
    ORDER BY h.rolname LIMIT 1
  ) holder ON r.oid<>@owner@
  WHERE db.datname=current_database() AND (
    NOT (r.oid=@owner@ OR r.rolsuper OR (r.rolname='pg_database_owner' AND (db.datdba=@owner@ OR dbowner.rolsuper)))
    OR holder.rolname IS NOT NULL)
  ORDER BY e.evtname LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'untrusted_dependency: event trigger %, function %, owner %, holder %',
      ownership_error.evtname,ownership_error.function_name,ownership_error.owner_name,ownership_error.holder;
  END IF;
  -- End event-trigger ownership.

  -- R3a: every non-predefined holder is refused, even without a reachable
  -- login: holder-owned views and SECURITY DEFINER routines can expose it.
  -- Predefined roles count when any subject has membership, including ADMIN
  -- without INHERIT or SET (an administrator can grant itself SET).
  -- Root DML is allowed; children and the maintenance ledger are owner-only,
  -- matching reset_acl. Replica mode would bypass the deletion and FK guards.
  WITH RECURSIVE scheduled(oid) AS (
    SELECT @maintenance@::oid WHERE @maintenance@<>@owner@
    UNION SELECT m.member FROM scheduled s JOIN pg_auth_members m ON m.roleid=s.oid WHERE m.member<>@owner@
  ), relations AS MATERIALIZED (
    SELECT t::oid AS oid,
      t NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass) AS owner_only
    FROM @routines@.ash_onetime_maintenance_relations() t
  ), holders AS MATERIALIZED (
    SELECT holder.oid,holder.rolname,
      CASE
        WHEN EXISTS (SELECT 1 FROM relations t WHERE has_table_privilege(holder.oid,t.oid,'MAINTAIN')) THEN 'MAINTAIN'
        WHEN EXISTS (SELECT 1 FROM relations t WHERE
          (has_table_privilege(holder.oid,t.oid,
            CASE WHEN t.owner_only THEN 'SELECT,INSERT,UPDATE,DELETE,TRIGGER,TRUNCATE,REFERENCES'
              ELSE 'TRIGGER,TRUNCATE,REFERENCES' END)
          OR has_any_column_privilege(holder.oid,t.oid,
            CASE WHEN t.owner_only THEN 'SELECT,INSERT,UPDATE,REFERENCES' ELSE 'REFERENCES' END))) THEN 'relation'
        WHEN has_parameter_privilege(holder.oid,'session_replication_role','SET, ALTER SYSTEM') THEN 'session_replication_role'
        WHEN pg_has_role(holder.oid,'pg_create_subscription','MEMBER') THEN 'replication'
      END AS authority
    FROM pg_roles holder WHERE NOT holder.rolsuper AND holder.oid<>@owner@
      AND NOT pg_has_role(holder.oid,@owner@,'USAGE')
      AND NOT pg_has_role(holder.oid,@owner@,'SET')
  ) SELECT holder.authority INTO authority_error FROM holders holder
    WHERE holder.authority IS NOT NULL AND (left(holder.rolname,3)<>'pg_' OR EXISTS (
      SELECT 1 FROM pg_roles r WHERE pg_has_role(r.oid,holder.oid,'MEMBER')
        AND (r.rolcanlogin OR r.oid IN (SELECT oid FROM scheduled)
          OR r.rolname=current_setting('role') OR r.rolname=current_user OR r.rolname=session_user)
        AND NOT r.rolsuper AND r.oid<>@owner@
        AND NOT pg_has_role(r.oid,@owner@,'USAGE') AND NOT pg_has_role(r.oid,@owner@,'SET')
    )) ORDER BY CASE holder.authority WHEN 'MAINTAIN' THEN 0 ELSE 1 END LIMIT 1;
  IF authority_error='MAINTAIN' THEN
    RAISE EXCEPTION 'untrusted_dependency: effective MAINTAIN privilege';
  ELSIF authority_error IS NOT NULL THEN
    RAISE EXCEPTION 'untrusted_dependency: effective % privilege',authority_error;
  END IF;
  -- Subscription ownership survives revocation of pg_create_subscription.
  -- Apply workers run in replica mode, bypassing ORIGIN and RI triggers.
  IF EXISTS (SELECT 1 FROM pg_subscription s JOIN pg_roles r ON r.oid=s.subowner
    WHERE s.subdbid=(SELECT oid FROM pg_database WHERE datname=current_database())
      AND NOT r.rolsuper AND r.oid<>@owner@
      AND NOT pg_has_role(r.oid,@owner@,'USAGE') AND NOT pg_has_role(r.oid,@owner@,'SET')) THEN
    RAISE EXCEPTION 'untrusted_dependency: effective subscription privilege';
  END IF;

END
