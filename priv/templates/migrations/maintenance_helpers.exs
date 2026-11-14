<% functions = [
  {"ash_onetime_cleanup_eligible", "retain_until timestamptz", "boolean", "eligible", false},
  {"ash_onetime_guard_idempotency_delete", "", "trigger", "guard_idempotency", false},
  {"ash_onetime_guard_nonce_delete", "", "trigger", "guard_nonce", false},
  {"ash_onetime_maintenance_active", "", "boolean", "active", false},
  {"ash_onetime_maintenance_relations", "", "SETOF oid", "relations", false},
  {"ash_onetime_maintenance_policy_error", "", "text", "policy", false},
  {"ash_onetime_maintenance_reset_acl", "relation_oid oid, owner_only boolean", "void", "reset_acl", false},
  {"ash_onetime_maintenance_copy_policy", "child_oid oid", "void", "copy_policy", false},
  {"ash_onetime_maintenance_lock", "exclusive_parent boolean, budget_ms integer", "void", "lock", false},
  {"ash_onetime_maintenance_edges", "class_oid oid, object_oid oid", "TABLE(classid oid, objectid oid, kind text)", "edges", false},
  {"ash_onetime_maintenance_trust", "", "void", "trust", false},
  {"ash_onetime_maintenance_acl", "", "boolean", "acl", false},
  {"ash_onetime_cleanup_idempotency", "batch_size integer", "bigint", "cleanup_idempotency", true},
  {"ash_onetime_cleanup_nonce", "batch_size integer", "bigint", "cleanup_nonce", true},
  {"ash_onetime_reap_idempotency", "batch_size integer, abandonment_seconds bigint", "bigint", "reap", true},
  {"ash_onetime_prune_payload_partitions", "partition_limit integer, lock_budget_ms integer", "jsonb", "prune", true},
  {"ash_onetime_roll_payload_partitions", "months_ahead integer", "bigint", "roll", true},
  {"ash_onetime_maintenance_status", "", "jsonb", "status", true}
] |> Enum.map(fn {name,args,result,file,definer} ->
  %{name: name, args: args, result: result, body: File.read!(Path.join([__DIR__,"maintenance",file <> ".sql"])), definer: definer}
end) %>
@maintenance_functions <%= inspect(functions, limit: :infinity, printable_limit: :infinity) %>
@maintenance_role <%= inspect(maintenance_role) %>

defp install_maintenance do
  execute("DO " <> maintenance_literal("""
  DECLARE
    install_schema text;
    owner_oid oid;
    owner_name text;
    migrating_role text := current_user;
    maintenance_oid oid;
    routine jsonb;
    routine_body text;
    routine_oid oid;
    grantee_oid oid;
    target record;
    fk record;
    anchor record;
    edge_query text := 'SELECT d.refclassid AS classid,d.refobjid AS objectid,''dependency''::text AS kind FROM pg_catalog.pg_depend d WHERE d.classid=$1 AND d.objid=$2 AND d.refclassid=ANY(ARRAY[''pg_class''::regclass,''pg_proc''::regclass,''pg_type''::regclass,''pg_operator''::regclass,''pg_opclass''::regclass,''pg_opfamily''::regclass,''pg_collation''::regclass,''pg_constraint''::regclass,''pg_attrdef''::regclass,''pg_rewrite''::regclass,''pg_am''::regclass,''pg_language''::regclass,''pg_transform''::regclass,''pg_ts_config''::regclass,''pg_ts_dict''::regclass,''pg_ts_parser''::regclass,''pg_ts_template''::regclass,''pg_conversion''::regclass,''pg_foreign_table''::regclass,''pg_foreign_server''::regclass,''pg_foreign_data_wrapper''::regclass])';
    value_sql text;
    edge_groups jsonb := '{}';
    edge_base text;
    edge_fragment text;
    edge_class text;
    edge_group record;
    schema_oid oid;
    old_functions jsonb;
    old_acls jsonb;
    manifest jsonb;
    policy_error text;
    expected_policy text;
  BEGIN
    SELECT n.nspname,c.relowner,n.oid INTO STRICT install_schema,owner_oid,schema_oid
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE c.oid=#{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass;
    owner_name := pg_catalog.pg_get_userbyid(owner_oid);
    IF NOT pg_catalog.pg_has_role(current_user,owner_oid,'SET') THEN
      RAISE EXCEPTION 'maintenance_owner_set_role: migrating role must be able to SET ROLE to %',owner_name;
    END IF;
    IF NOT pg_catalog.has_schema_privilege(owner_oid,schema_oid,'CREATE') THEN
      RAISE EXCEPTION 'maintenance_owner_schema_create: owner % needs CREATE on schema %',owner_name,install_schema;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.pronamespace=schema_oid
      AND p.proname IN (SELECT x->>'name' FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x)
      AND NOT pg_catalog.pg_has_role(current_user,p.proowner,'USAGE')) THEN
      RAISE EXCEPTION 'maintenance_function_ownership: migrating role must own every replaced function';
    END IF;
    maintenance_oid := CASE WHEN #{@maintenance_role |> maintenance_literal()} IS NULL THEN owner_oid
      ELSE (SELECT oid FROM pg_catalog.pg_roles WHERE rolname=#{@maintenance_role |> maintenance_literal()}) END;
    IF maintenance_oid IS NULL THEN RAISE EXCEPTION 'maintenance_role_missing: declared maintenance role does not exist'; END IF;
    SELECT string_agg(column_name,', ' ORDER BY column_name) INTO policy_error
    FROM unnest(ARRAY['starelid','staop1','staop2','staop3','staop4','staop5',
      'stacoll1','stacoll2','stacoll3','stacoll4','stacoll5']) column_name
    WHERE NOT has_column_privilege(owner_oid,'pg_catalog.pg_statistic',column_name,'SELECT');
    IF policy_error IS NOT NULL THEN
      RAISE EXCEPTION 'maintenance_catalog_access: owner % requires metadata column SELECT (%) ON pg_catalog.pg_statistic',owner_name,policy_error;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
      WHERE attrelid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass
        AND attname='hold_reference' AND NOT attisdropped)
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass
          AND conname='ash_onetime_idempotency_claims_hold_check' AND convalidated) THEN
      RAISE EXCEPTION 'operation_hold_required: apply the 1.10.0 operation-hold migration first';
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object('definition',pg_get_functiondef(p.oid),'owner',pg_get_userbyid(p.proowner))),'[]')
    INTO old_functions FROM pg_proc p WHERE p.pronamespace=schema_oid
      AND p.proname IN ('ash_onetime_cleanup_idempotency','ash_onetime_cleanup_nonce','ash_onetime_reap_idempotency',
        'ash_onetime_cleanup_eligible','ash_onetime_guard_nonce_delete','ash_onetime_guard_idempotency_delete');
    WITH RECURSIVE relations(oid) AS (
      SELECT unnest(ARRAY[format('%I.ash_onetime_idempotency_claims',install_schema)::regclass::oid,
        format('%I.ash_onetime_nonce_claims',install_schema)::regclass::oid,
        format('%I.ash_onetime_response_payloads',install_schema)::regclass::oid])
      UNION SELECT i.inhrelid FROM relations r JOIN pg_inherits i ON i.inhparent=r.oid
    ), objects AS (
      SELECT 'table' AS kind,c.oid,0 AS column_number,c.relowner AS owner,
        coalesce(c.relacl,acldefault('r',c.relowner)) AS acl FROM pg_class c JOIN relations r USING(oid)
      UNION ALL SELECT 'column',a.attrelid,a.attnum,c.relowner,a.attacl
        FROM pg_attribute a JOIN relations r ON r.oid=a.attrelid JOIN pg_class c ON c.oid=a.attrelid
        WHERE a.attacl IS NOT NULL AND NOT a.attisdropped
      UNION ALL SELECT 'function',p.oid,0,p.proowner,coalesce(p.proacl,acldefault('f',p.proowner))
        FROM pg_proc p WHERE p.pronamespace=schema_oid
          AND p.proname IN ('ash_onetime_cleanup_idempotency','ash_onetime_cleanup_nonce','ash_onetime_reap_idempotency',
            'ash_onetime_cleanup_eligible','ash_onetime_guard_nonce_delete','ash_onetime_guard_idempotency_delete')
    ) SELECT coalesce(jsonb_agg(jsonb_build_object('kind',o.kind,'oid',o.oid,'column',o.column_number,'owner',o.owner,
      'grants',coalesce((SELECT jsonb_agg(jsonb_build_object('grantee',a.grantee,'privilege',a.privilege_type,'grantable',a.is_grantable))
        FROM aclexplode(o.acl) a),'[]'))),'[]') INTO old_acls FROM objects o;
    EXECUTE format('CREATE TABLE %I.ash_onetime_maintenance_runs (step text PRIMARY KEY CHECK (step IN (''install'',''roll'',''cleanup'',''reap'',''prune'')), installed_at timestamptz, last_success_at timestamptz, last_counts jsonb NOT NULL DEFAULT ''{}'', last_refusals jsonb NOT NULL DEFAULT ''{}'', updated_at timestamptz NOT NULL DEFAULT clock_timestamp())',install_schema);
    EXECUTE format('INSERT INTO %I.ash_onetime_maintenance_runs(step,installed_at,last_counts) VALUES (''install'',clock_timestamp(),$1)',install_schema)
      USING jsonb_build_object('previous_functions',old_functions,'previous_acls',old_acls,'maintenance_role',maintenance_oid);
    EXECUTE format('INSERT INTO %I.ash_onetime_maintenance_runs(step) VALUES (''roll''),(''cleanup''),(''reap''),(''prune'')',install_schema);
    EXECUTE format('ALTER TABLE %I.ash_onetime_maintenance_runs OWNER TO %I',install_schema,owner_name);

    -- Typed catalog edges, derived from PostgreSQL's own foreign-key inventory.
    -- Containment is explicit, including catalogs whose identity is not an OID.
    FOR fk IN SELECT * FROM pg_catalog.pg_get_catalog_foreign_keys()
      WHERE pkcols=ARRAY['oid']::text[] AND cardinality(fkcols)=1
        AND fktable IN ('pg_class'::regclass,'pg_proc'::regclass,'pg_type'::regclass,'pg_operator'::regclass,
          'pg_opclass'::regclass,'pg_opfamily'::regclass,'pg_collation'::regclass,'pg_constraint'::regclass,'pg_cast'::regclass,
          'pg_attrdef'::regclass,'pg_attribute'::regclass,'pg_index'::regclass,'pg_partitioned_table'::regclass,
          'pg_trigger'::regclass,'pg_policy'::regclass,'pg_rewrite'::regclass,'pg_statistic'::regclass,'pg_statistic_ext'::regclass,
          'pg_sequence'::regclass,'pg_foreign_table'::regclass,'pg_amop'::regclass,'pg_amproc'::regclass,
          'pg_range'::regclass,'pg_aggregate'::regclass,'pg_am'::regclass,'pg_language'::regclass,
          'pg_transform'::regclass,'pg_ts_config'::regclass,'pg_ts_config_map'::regclass,'pg_ts_dict'::regclass,
          'pg_ts_parser'::regclass,'pg_ts_template'::regclass,'pg_conversion'::regclass,
          'pg_foreign_server'::regclass,'pg_foreign_data_wrapper'::regclass)
        AND pktable IN ('pg_class'::regclass,'pg_proc'::regclass,'pg_type'::regclass,'pg_operator'::regclass,
          'pg_opclass'::regclass,'pg_opfamily'::regclass,'pg_collation'::regclass,'pg_constraint'::regclass,
          'pg_am'::regclass,'pg_language'::regclass,'pg_transform'::regclass,'pg_ts_config'::regclass,
          'pg_ts_dict'::regclass,'pg_ts_parser'::regclass,'pg_ts_template'::regclass,'pg_conversion'::regclass,
          'pg_foreign_server'::regclass,'pg_foreign_data_wrapper'::regclass)
    LOOP
      value_sql := CASE WHEN fk.is_array THEN format('unnest(c.%I)',fk.fkcols[1]) ELSE format('unnest(ARRAY[c.%I])',fk.fkcols[1]) END;
      IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=fk.fktable AND attname='oid' AND NOT attisdropped) THEN
        edge_query := edge_query || format(' UNION ALL SELECT %s::oid,v.id::oid,%L::text FROM %s c CROSS JOIN LATERAL %s v(id) WHERE $1=%s::oid AND c.oid=$2 AND v.id<>0',
          fk.pktable::oid,fk.fktable::text || '.' || fk.fkcols[1],fk.fktable,value_sql,fk.fktable::oid);
      END IF;
      FOR anchor IN SELECT * FROM (VALUES
        ('pg_attribute','attrelid','pg_class'),('pg_attrdef','adrelid','pg_class'),
        ('pg_constraint','conrelid','pg_class'),('pg_constraint','confrelid','pg_class'),('pg_constraint','contypid','pg_type'),
        ('pg_index','indrelid','pg_class'),('pg_index','indexrelid','pg_class'),
        ('pg_partitioned_table','partrelid','pg_class'),('pg_trigger','tgrelid','pg_class'),
        ('pg_policy','polrelid','pg_class'),('pg_rewrite','ev_class','pg_class'),
        ('pg_statistic','starelid','pg_class'),('pg_statistic_ext','stxrelid','pg_class'),
        ('pg_sequence','seqrelid','pg_class'),('pg_foreign_table','ftrelid','pg_class'),
        ('pg_amop','amopfamily','pg_opfamily'),('pg_amproc','amprocfamily','pg_opfamily'),
        ('pg_range','rngtypid','pg_type'),('pg_range','rngmultitypid','pg_type'),
        ('pg_aggregate','aggfnoid','pg_proc'),
        ('pg_ts_config_map','mapcfg','pg_ts_config')
      ) a(catalog,column_name,parent_catalog) WHERE a.catalog::regclass=fk.fktable
      LOOP
        edge_query := edge_query || format(' UNION ALL SELECT %s::oid,v.id::oid,%L::text FROM %s c CROSS JOIN LATERAL %s v(id) WHERE $1=%L::regclass AND c.%I=$2 AND v.id<>0%s',
          fk.pktable::oid,fk.fktable::text || '.' || fk.fkcols[1],fk.fktable,value_sql,anchor.parent_catalog,anchor.column_name,
          CASE WHEN anchor.catalog='pg_policy' THEN format(' AND EXISTS (SELECT 1 FROM unnest(c.polroles) x WHERE x=0 OR pg_has_role(%s::oid,x,''MEMBER''))',owner_oid) ELSE '' END);
        IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=fk.fktable AND attname='oid' AND NOT attisdropped) THEN
          edge_query := edge_query || format(' UNION ALL SELECT %s::oid,c.oid,%L::text FROM %s c WHERE $1=%L::regclass AND c.%I=$2%s',
            fk.fktable::oid,'containment',fk.fktable,anchor.parent_catalog,anchor.column_name,
            CASE WHEN anchor.catalog='pg_policy' THEN format(' AND EXISTS (SELECT 1 FROM unnest(c.polroles) x WHERE x=0 OR pg_has_role(%s::oid,x,''MEMBER''))',owner_oid) ELSE '' END);
        END IF;
      END LOOP;
    END LOOP;
    edge_query := edge_query || ' UNION ALL SELECT ''pg_class''::regclass,i.inhrelid,''partition'' FROM pg_inherits i WHERE $1=''pg_class''::regclass AND i.inhparent=$2';
    edge_query := edge_query || ' UNION ALL SELECT ''pg_transform''::regclass,t.oid,''pg_proc.protrftypes'' FROM pg_proc p JOIN pg_transform t ON t.trflang=p.prolang AND t.trftype=ANY(p.protrftypes) WHERE $1=''pg_proc''::regclass AND p.oid=$2';
    -- Cache one small typed query per source catalog. A single union of
    -- every catalog replans unrelated branches on each traversal node.
    edge_base := split_part(edge_query,' UNION ALL ',1);
    FOR edge_fragment IN SELECT unnest(string_to_array(edge_query,' UNION ALL ')) LOOP
      CONTINUE WHEN edge_fragment=edge_base;
      edge_class := substring(edge_fragment FROM '[$]1=([0-9]+)::oid');
      IF edge_class IS NULL THEN
        edge_class := (substring(edge_fragment FROM '[$]1=''([^'']+)''::regclass')::regclass::oid)::text;
      END IF;
      IF edge_class IS NULL THEN RAISE EXCEPTION 'maintenance_catalog_shape: untyped catalog edge'; END IF;
      edge_groups := jsonb_set(edge_groups,ARRAY[edge_class],to_jsonb(coalesce(edge_groups->>edge_class,edge_base) || ' UNION ALL ' || edge_fragment));
    END LOOP;
    edge_query := 'CASE class_oid ';
    FOR edge_group IN SELECT key,value FROM jsonb_each_text(edge_groups) LOOP
      edge_query := edge_query || format(' WHEN %s THEN RETURN QUERY %s;',edge_group.key::oid,edge_group.value);
    END LOOP;
    edge_query := edge_query || ' ELSE RETURN QUERY ' || edge_base || '; END CASE;';

    FOR routine IN SELECT * FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb)
    LOOP
      routine_body := replace(replace(replace(replace(replace(replace(replace(routine->>'body',
        '@schema@',format('%I',install_schema)), '@owner@',owner_oid::text),
        '@schema_name@',quote_literal(install_schema)),
        '@idempotency@',quote_literal(format('%I.ash_onetime_idempotency_claims',install_schema))),
        '@nonce@',quote_literal(format('%I.ash_onetime_nonce_claims',install_schema))),
        '@payload@',quote_literal(format('%I.ash_onetime_response_payloads',install_schema))),
        '@edges@',edge_query);
      EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE plpgsql SECURITY %s SET search_path = pg_catalog, pg_temp AS %L',
        install_schema,routine->>'name',routine->>'args',routine->>'result',
        CASE WHEN (routine->>'definer')::boolean THEN 'DEFINER' ELSE 'INVOKER' END,routine_body);
      -- Argument names are accepted by CREATE, but regprocedure takes types.
      SELECT p.oid INTO STRICT routine_oid FROM pg_proc p WHERE p.pronamespace=schema_oid AND p.proname=routine->>'name';
      FOR grantee_oid IN SELECT DISTINCT a.grantee FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=routine_oid AND a.grantee<>owner_oid
      LOOP
        EXECUTE format('REVOKE ALL PRIVILEGES ON FUNCTION %s FROM %s CASCADE',routine_oid::regprocedure,
          CASE WHEN grantee_oid=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee_oid)) END);
      END LOOP;
      IF (routine->>'definer')::boolean OR routine->>'name'='ash_onetime_maintenance_active' THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',routine_oid::regprocedure,pg_get_userbyid(maintenance_oid));
      END IF;
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',routine_oid::regprocedure,owner_name);
      EXECUTE format('ALTER FUNCTION %s OWNER TO %I',routine_oid::regprocedure,owner_name);
    END LOOP;

    -- SET capability is sufficient; an owner need not be inherited or able
    -- to log in. The caller's role is restored on the normal exit.
    PERFORM set_config('role',owner_name,true);
    FOR target IN SELECT c.oid,c.relowner,format('%I.%I',n.nspname,c.relname) AS relation_name
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid IN (SELECT * FROM #{q("ash_onetime_maintenance_relations")}())
    LOOP
      IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid=target.oid AND polname='ash_onetime_maintenance') THEN
        RAISE EXCEPTION 'maintenance_blinded: reserved policy ash_onetime_maintenance already exists on %',target.relation_name;
      END IF;
      EXECUTE format('CREATE POLICY ash_onetime_maintenance ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active()) WITH CHECK (%I.ash_onetime_maintenance_active())',
        target.relation_name,owner_name,install_schema,install_schema);
      PERFORM #{q("ash_onetime_maintenance_reset_acl")}(target.oid,
        target.oid NOT IN (format('%I.ash_onetime_idempotency_claims',install_schema)::regclass,
          format('%I.ash_onetime_nonce_claims',install_schema)::regclass,format('%I.ash_onetime_response_payloads',install_schema)::regclass));
    END LOOP;
    SELECT regexp_replace(polqual::text,':location [-0-9]+',':location -1','g') INTO STRICT expected_policy
    FROM pg_policy WHERE polrelid=format('%I.ash_onetime_response_payloads',install_schema)::regclass
      AND polname='ash_onetime_maintenance';
    SELECT prosrc INTO STRICT routine_body FROM pg_proc WHERE pronamespace=schema_oid AND proname='ash_onetime_maintenance_policy_error';
    routine_body := replace(routine_body,quote_literal('@policy_expression@'),quote_literal(expected_policy));
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_policy_error() RETURNS text LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,pg_temp AS %L',install_schema,routine_body);
    SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'name',p.proname,'arguments',p.proargtypes::text,
      'owner',p.proowner,'definer',p.prosecdef,'config',to_jsonb(p.proconfig),'digest',encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')))
    INTO manifest FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.pronamespace=schema_oid
      AND p.proname IN (SELECT x->>'name' FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x)
      AND p.proname<>'ash_onetime_maintenance_trust';
    SELECT prosrc INTO STRICT routine_body FROM pg_proc WHERE pronamespace=schema_oid AND proname='ash_onetime_maintenance_trust';
    routine_body := replace(routine_body,quote_literal('[]') || '::jsonb; -- @routine_manifest@',quote_literal(manifest::text) || '::jsonb;');
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_trust() RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,pg_temp AS %L',install_schema,routine_body);
    SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'name',p.proname,'arguments',p.proargtypes::text,
      'owner',p.proowner,'definer',p.prosecdef,'config',to_jsonb(p.proconfig),'digest',encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')))
    INTO manifest FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.pronamespace=schema_oid
      AND p.proname IN (SELECT x->>'name' FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x);
    EXECUTE format('UPDATE %I.ash_onetime_maintenance_runs SET last_counts=last_counts || jsonb_build_object(''routines'',$1) WHERE step=''install''',install_schema) USING manifest;
    policy_error := #{q("ash_onetime_maintenance_policy_error")}();
    IF policy_error IS NOT NULL THEN RAISE EXCEPTION 'maintenance_blinded: %',policy_error; END IF;
    PERFORM #{q("ash_onetime_maintenance_lock")}(false,5000);
    PERFORM #{q("ash_onetime_maintenance_trust")}();
    PERFORM set_config('role',migrating_role,true);
  END
  """))
end

defp maintenance_literal(nil), do: "NULL"
defp maintenance_literal(value), do: "E'" <> (value |> String.replace("\\", "\\\\") |> String.replace("'", "''")) <> "'"
