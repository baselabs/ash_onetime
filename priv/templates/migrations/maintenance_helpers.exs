@maintenance_functions <%= EEx.eval_file(Path.join(__DIR__, "maintenance_routines.exs"), binding()) |> String.trim() %>
@maintenance_role <%= inspect(maintenance_role) %>

defp install_maintenance(mode) when mode in [:fresh, :upgrade] do
  flush()
  execute("DO " <> maintenance_literal("""
  DECLARE
    install_schema text;
    routine_schema text;
    routine_schema_oid oid;
    old_routine jsonb;
    owner_oid oid;
    owner_name text;
    migrating_role text := current_user;
    maintenance_oid oid;
    routine jsonb;
    routine_body text;
    routine_oid oid;
    -- Function settings are restored by PostgreSQL when each call exits.
    routine_settings text := <%= "#" <> "{maintenance_literal(" <> inspect(EEx.eval_file(Path.join([__DIR__, "maintenance", "settings.sql"]), fragment: :top_level) |> String.trim()) <> ")}" %>;
    grantee_oid oid;
    grantee oid;
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
    actual_shape jsonb;
    expected_shape jsonb;
    shape_key text;
    policy_error text;
    expected_policy text;
    expected_visibility text;
  BEGIN
    SELECT n.nspname,c.relowner,n.oid INTO STRICT install_schema,owner_oid,schema_oid
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE c.oid=#{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass;
    owner_name := pg_catalog.pg_get_userbyid(owner_oid);
    routine_schema := 'ash_onetime_' || substr(encode(sha256(convert_to(install_schema,'UTF8')),'hex'),1,48);
    IF NOT pg_catalog.pg_has_role(current_user,owner_oid,'SET') THEN
      -- rule:install-owner-set-role
      RAISE EXCEPTION 'maintenance_owner_set_role: migrating role must be able to SET ROLE to %',owner_name;
    END IF;
    IF NOT pg_catalog.has_schema_privilege(owner_oid,schema_oid,'CREATE') THEN
      -- rule:install-owner-schema-create
      RAISE EXCEPTION 'maintenance_owner_schema_create: owner % needs CREATE on schema %',owner_name,install_schema;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.pronamespace=schema_oid
      AND p.oid IN (SELECT to_regprocedure(format('%I.%I(%s)',install_schema,x->>'name',x->>'types')) FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x)
      AND NOT pg_catalog.pg_has_role(current_user,p.proowner,'USAGE')) THEN
      -- rule:install-function-ownership
      RAISE EXCEPTION 'maintenance_function_ownership: migrating role must own every replaced function';
    END IF;
    maintenance_oid := CASE WHEN #{@maintenance_role |> maintenance_literal()} IS NULL THEN owner_oid
      ELSE (SELECT oid FROM pg_catalog.pg_roles WHERE rolname=#{@maintenance_role |> maintenance_literal()}) END;
    -- rule:install-maintenance-role-exists
    IF maintenance_oid IS NULL THEN RAISE EXCEPTION 'maintenance_role_missing: declared maintenance role does not exist'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute
      WHERE attrelid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass
        AND attname='hold_reference' AND NOT attisdropped)
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass
          AND conname='ash_onetime_idempotency_claims_hold_check' AND convalidated) THEN
      -- rule:maintenance-hold-required
      RAISE EXCEPTION 'operation_hold_required: apply the 2.0 operation-hold migration first';
    END IF;

    IF to_regclass(format('%I.ash_onetime_effect_outcomes',install_schema)) IS NULL
      OR NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass AND attname='effect_local' AND NOT attisdropped) THEN
      -- rule:maintenance-external-required
      RAISE EXCEPTION 'untrusted_dependency: upgrade relation shape ash_onetime_idempotency_claims';
    END IF;

    IF #{mode == :upgrade} THEN
      PERFORM set_config('role',owner_name,true);
      PERFORM set_config('lock_timeout','5s',true);
      LOCK TABLE #{q("ash_onetime_idempotency_claims")}, #{q("ash_onetime_effect_outcomes")} IN ACCESS EXCLUSIVE MODE;
      PERFORM set_config('role',migrating_role,true);
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object('oid',p.oid,'identity',p.oid::regprocedure::text,'definition',pg_get_functiondef(p.oid),'owner',pg_get_userbyid(p.proowner))),'[]')
    INTO old_functions FROM pg_proc p WHERE p.pronamespace=schema_oid
      AND p.proname IN ('ash_onetime_cleanup_idempotency','ash_onetime_cleanup_nonce','ash_onetime_reap_idempotency',
        'ash_onetime_cleanup_eligible','ash_onetime_guard_nonce_delete','ash_onetime_guard_idempotency_delete','ash_onetime_guard_idempotency_update','ash_onetime_guard_effect_outcome',
        'ash_onetime_bound_effect_outcome','ash_onetime_claim_visible','ash_onetime_expire_responses',
        'ash_onetime_maintenance_active','ash_onetime_maintenance_reset_acl')
      AND p.oid IN (SELECT to_regprocedure(format('%I.%I(%s)',install_schema,x->>'name',x->>'types')) FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x);
    WITH RECURSIVE relations(oid) AS (
      SELECT unnest(ARRAY[format('%I.ash_onetime_idempotency_claims',install_schema)::regclass::oid,
        format('%I.ash_onetime_nonce_claims',install_schema)::regclass::oid,
        format('%I.ash_onetime_response_payloads',install_schema)::regclass::oid,
        format('%I.ash_onetime_effect_outcomes',install_schema)::regclass::oid])
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
            'ash_onetime_cleanup_eligible','ash_onetime_guard_nonce_delete','ash_onetime_guard_idempotency_delete','ash_onetime_guard_idempotency_update','ash_onetime_guard_effect_outcome',
        'ash_onetime_bound_effect_outcome','ash_onetime_claim_visible','ash_onetime_expire_responses',
        'ash_onetime_maintenance_active','ash_onetime_maintenance_reset_acl')
          AND p.oid IN (SELECT to_regprocedure(format('%I.%I(%s)',install_schema,x->>'name',x->>'types')) FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x)
    ) SELECT coalesce(jsonb_agg(jsonb_build_object('kind',o.kind,'oid',o.oid,'column',o.column_number,'owner',o.owner,
      'grants',coalesce((SELECT jsonb_agg(jsonb_build_object('grantor',a.grantor,'grantee',a.grantee,'privilege',a.privilege_type,'grantable',a.is_grantable))
        FROM aclexplode(o.acl) a),'[]'))),'[]') INTO old_acls FROM objects o;
    -- Transfer while the migrator still owns the old functions. After schema
    -- creation, use SET ROLE before touching the owner's namespace ACL.
    FOR old_routine IN SELECT * FROM jsonb_array_elements(old_functions) LOOP
      EXECUTE format('ALTER FUNCTION %s OWNER TO %I',(old_routine->>'oid')::oid::regprocedure,owner_name);
    END LOOP;
    EXECUTE format('CREATE SCHEMA %I AUTHORIZATION %I',routine_schema,owner_name);
    PERFORM set_config('role',owner_name,true);
    IF #{mode == :fresh} THEN
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "restore.sql"]), fragment: :create) %>
    END IF;
    -- rule:private-routine-schema
    EXECUTE format('REVOKE ALL PRIVILEGES ON SCHEMA %I FROM PUBLIC',routine_schema);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I',routine_schema,pg_get_userbyid(maintenance_oid));
    SELECT oid INTO STRICT routine_schema_oid FROM pg_namespace WHERE nspname=routine_schema;
    FOR old_routine IN SELECT * FROM jsonb_array_elements(old_functions) LOOP
      EXECUTE format('ALTER FUNCTION %s SET SCHEMA %I',(old_routine->>'oid')::oid::regprocedure,routine_schema);
    END LOOP;
    EXECUTE replace(<%= "#" <> "{maintenance_literal(" <> inspect(File.read!(Path.join([__DIR__, "maintenance", "runs.sql"]))) <> ")}" %>,'@schema@',format('%I',install_schema));
    EXECUTE format('INSERT INTO %I.ash_onetime_maintenance_runs(step,installed_at,last_counts) VALUES (''install'',clock_timestamp(),$1)',install_schema)
      USING jsonb_build_object('previous_functions',old_functions,'previous_acls',old_acls,'maintenance_role',maintenance_oid,'table_schema',install_schema,'routine_schema',routine_schema);
    EXECUTE format('INSERT INTO %I.ash_onetime_maintenance_runs(step) VALUES (''roll''),(''cleanup''),(''reap''),(''prune'')',install_schema);
    EXECUTE format('ALTER TABLE %I.ash_onetime_maintenance_runs OWNER TO %I',install_schema,owner_name);

    -- Typed catalog edges, derived from PostgreSQL's own foreign-key inventory.
    -- Containment is explicit, including catalogs whose identity is not an OID.
    FOR fk IN SELECT * FROM pg_catalog.pg_get_catalog_foreign_keys()
      WHERE pkcols=ARRAY['oid']::text[] AND cardinality(fkcols)=1
        AND fktable IN ('pg_class'::regclass,'pg_proc'::regclass,'pg_type'::regclass,'pg_operator'::regclass,
          'pg_opclass'::regclass,'pg_opfamily'::regclass,'pg_collation'::regclass,'pg_constraint'::regclass,'pg_cast'::regclass,
          'pg_attrdef'::regclass,'pg_attribute'::regclass,'pg_index'::regclass,'pg_partitioned_table'::regclass,
          'pg_trigger'::regclass,'pg_policy'::regclass,'pg_rewrite'::regclass,'pg_statistic_ext'::regclass,
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
        ('pg_statistic_ext','stxrelid','pg_class'),
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
      -- rule:catalog-edge-numeric-class
      edge_class := substring(edge_fragment FROM '[$]1=([0-9]+)::oid');
      IF edge_class IS NULL THEN
        -- rule:catalog-edge-named-class
        edge_class := (substring(edge_fragment FROM '[$]1=''([^'']+)''::regclass')::regclass::oid)::text;
      END IF;
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
      routine_body := replace(routine_body,'@outcomes@',quote_literal(format('%I.ash_onetime_effect_outcomes',install_schema)));
      routine_body := replace(replace(replace(routine_body,'@routines@',format('%I',routine_schema)),
        '@routine_schema_name@',quote_literal(routine_schema)),'@maintenance@',maintenance_oid::text);
      -- rule:install-routine-security
      EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE %s %s SECURITY %s %s AS %L',
        routine_schema,routine->>'name',routine->>'args',routine->>'result',routine->>'language',
        CASE WHEN routine->>'language'='sql' THEN 'STABLE' ELSE 'VOLATILE' END,
        routine->>'security',
        routine->>'settings',routine_body);
      -- Argument names are accepted by CREATE, but regprocedure takes types.
      routine_oid := to_regprocedure(format('%I.%I(%s)',routine_schema,routine->>'name',routine->>'types'));
      FOR grantee_oid IN SELECT DISTINCT a.grantee FROM pg_proc p,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=routine_oid AND a.grantee<>owner_oid
      LOOP
        EXECUTE format('REVOKE ALL PRIVILEGES ON FUNCTION %s FROM %s CASCADE',routine_oid::regprocedure,
          CASE WHEN grantee_oid=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee_oid)) END);
      END LOOP;
      IF routine->>'grant_class'='step' OR routine->>'name'='ash_onetime_maintenance_active' THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',routine_oid::regprocedure,pg_get_userbyid(maintenance_oid));
      END IF;
      IF routine->>'grant_class'='public_invoker' THEN
        <%= EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :visible_acl) %>
      END IF;
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',routine_oid::regprocedure,owner_name);
      EXECUTE format('ALTER FUNCTION %s OWNER TO %I',routine_oid::regprocedure,owner_name);
    END LOOP;

    -- SET capability is sufficient; an owner need not be inherited or able
    -- to log in. The caller's role is restored on the normal exit.
    PERFORM set_config('role',owner_name,true);
    FOR target IN SELECT c.oid,c.relowner,format('%I.%I',n.nspname,c.relname) AS relation_name
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid IN (SELECT * FROM #{rq("ash_onetime_maintenance_relations")}())
    LOOP
      IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid=target.oid AND polname='ash_onetime_maintenance') THEN
        EXECUTE format('
        -- rule:install-upgrade-policy-policy
        CREATE POLICY ash_onetime_upgrade_policy ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())
        -- rule:install-upgrade-policy-check
        WITH CHECK (%I.ash_onetime_maintenance_active())',target.relation_name,owner_name,routine_schema,routine_schema);
        IF NOT EXISTS (SELECT 1 FROM pg_policy old JOIN pg_policy expected ON old.polrelid=expected.polrelid
          WHERE old.polrelid=target.oid AND old.polname='ash_onetime_maintenance' AND expected.polname='ash_onetime_upgrade_policy'
            AND old.polroles=expected.polroles AND old.polcmd=expected.polcmd AND old.polpermissive=expected.polpermissive
            AND #{rq("ash_onetime_maintenance_normalize")}(old.polqual::text,target.oid)=#{rq("ash_onetime_maintenance_normalize")}(expected.polqual::text,target.oid)
            AND #{rq("ash_onetime_maintenance_normalize")}(old.polwithcheck::text,target.oid)=#{rq("ash_onetime_maintenance_normalize")}(expected.polwithcheck::text,target.oid)) THEN
          -- rule:install-reserved-policy-refusal
          RAISE EXCEPTION 'maintenance_blinded: reserved policy ash_onetime_maintenance already exists on %',target.relation_name;
        END IF;
        EXECUTE format('DROP POLICY ash_onetime_upgrade_policy ON %s',target.relation_name);
      ELSE
        EXECUTE format('
        -- rule:install-maintenance-policy
        CREATE POLICY ash_onetime_maintenance ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())
        -- rule:install-maintenance-check
        WITH CHECK (%I.ash_onetime_maintenance_active())',
          target.relation_name,owner_name,routine_schema,routine_schema);
      END IF;
      -- rule:install-outcome-append-only
      PERFORM #{rq("ash_onetime_maintenance_reset_acl")}(target.oid,
        (target.oid NOT IN (format('%I.ash_onetime_idempotency_claims',install_schema)::regclass,
          format('%I.ash_onetime_nonce_claims',install_schema)::regclass,format('%I.ash_onetime_response_payloads',install_schema)::regclass,format('%I.ash_onetime_effect_outcomes',install_schema)::regclass) AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=target.oid AND inhparent=format('%I.ash_onetime_effect_outcomes',install_schema)::regclass))::boolean);
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=format('%I.ash_onetime_nonce_claims',install_schema)::regclass AND tgname='ash_onetime_nonce_delete_guard') THEN
      EXECUTE format('CREATE TRIGGER ash_onetime_nonce_delete_guard BEFORE DELETE ON %I.ash_onetime_nonce_claims FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_nonce_delete()',install_schema,routine_schema);
      -- rule:M-firing-nonce
      EXECUTE format('ALTER TABLE %I.ash_onetime_nonce_claims ENABLE ALWAYS TRIGGER ash_onetime_nonce_delete_guard',install_schema);
      EXECUTE format('CREATE TRIGGER ash_onetime_idempotency_delete_guard BEFORE DELETE ON %I.ash_onetime_idempotency_claims FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_idempotency_delete()',install_schema,routine_schema);
      -- rule:M-firing-claims
      EXECUTE format('ALTER TABLE %I.ash_onetime_idempotency_claims ENABLE ALWAYS TRIGGER ash_onetime_idempotency_delete_guard',install_schema);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=format('%I.ash_onetime_effect_outcomes',install_schema)::regclass AND tgname='ash_onetime_effect_outcome_guard') THEN
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :triggers) %>
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass AND tgname='ash_onetime_idempotency_update_guard') THEN
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: :trigger_attachment) %>
    END IF;
    FOR target IN WITH RECURSIVE outcomes(oid) AS (
      SELECT format('%I.ash_onetime_effect_outcomes',install_schema)::regclass::oid
      UNION SELECT i.inhrelid FROM pg_inherits i JOIN outcomes o ON o.oid=i.inhparent
    ) SELECT c.oid,c.relkind FROM outcomes o JOIN pg_class c USING (oid) LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid=target.oid AND polname='ash_onetime_claim_visibility') THEN
      EXECUTE format('
        -- rule:install-claim-visibility-policy
        CREATE POLICY ash_onetime_claim_visibility ON %s AS PERMISSIVE FOR ALL TO PUBLIC USING (%I.ash_onetime_claim_visible(%sclaim_id))
        -- rule:install-claim-visibility-check
        WITH CHECK (%I.ash_onetime_claim_visible(%sclaim_id))',
        target.oid::regclass,routine_schema,
        CASE WHEN (SELECT relkind FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass)='p' THEN 'operation_hash,logical_partition,' ELSE 'NULL::bytea,NULL::text,' END,
        routine_schema,CASE WHEN (SELECT relkind FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass)='p' THEN 'operation_hash,logical_partition,' ELSE 'NULL::bytea,NULL::text,' END);
      END IF;
      IF (SELECT relrowsecurity FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass) THEN
        EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',target.oid::regclass);
      END IF;
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :rls) %>
    END LOOP;
    -- Fresh objects are captured in the creating transaction. Upgrades use
    -- the package DDL reference, not the existing consumer's expressions.
    -- rule:maintenance-upgrade-reference
    IF #{mode == :fresh} THEN
      manifest := #{rq("ash_onetime_maintenance_capture")}();
    ELSE
      manifest := #{rq("ash_onetime_maintenance_reference")}(false::boolean);
      PERFORM #{rq("ash_onetime_maintenance_lock")}(true::boolean,5000::integer);
      FOR target IN SELECT c.oid,c.relname,p.relname AS parent_name
        FROM #{rq("ash_onetime_maintenance_relations")}() r JOIN pg_class c ON c.oid=r
        LEFT JOIN pg_inherits i ON i.inhrelid=c.oid LEFT JOIN pg_class p ON p.oid=i.inhparent
      LOOP
        shape_key := coalesce(target.parent_name,target.relname) || CASE WHEN target.parent_name IS NULL THEN '' ELSE '_child' END;
        expected_shape := CASE WHEN target.parent_name IS NOT NULL AND target.parent_name<>'ash_onetime_response_payloads'
          THEN manifest->(target.parent_name || '_children')->(SELECT regexp_replace(relpartbound::text,':location [-0-9]+',':location -1','g') FROM pg_class WHERE oid=target.oid)
          ELSE manifest->shape_key END;
        actual_shape := #{rq("ash_onetime_maintenance_shape")}(target.oid::oid);
        IF actual_shape IS DISTINCT FROM expected_shape THEN
          -- rule:maintenance-upgrade-validation
          RAISE EXCEPTION 'untrusted_dependency: upgrade relation shape %',target.relname;
        END IF;
      END LOOP;
    END IF;
    SELECT prosrc INTO STRICT routine_body FROM pg_proc WHERE oid=format('%I.ash_onetime_maintenance_shapes()',routine_schema)::regprocedure;
    routine_body := replace(routine_body,quote_literal('{}') || '::jsonb; -- @relation_manifest@',quote_literal(manifest::text) || '::jsonb;');
    -- rule:install-shapes-invoker
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_shapes() RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER %s AS %L',routine_schema,routine_settings,routine_body);
    SELECT #{rq("ash_onetime_maintenance_normalize")}(polqual::text,polrelid::oid) INTO STRICT expected_policy
    FROM pg_policy WHERE polrelid=format('%I.ash_onetime_response_payloads',install_schema)::regclass
      AND polname='ash_onetime_maintenance';
    SELECT #{rq("ash_onetime_maintenance_normalize")}(polqual::text,polrelid::oid) INTO STRICT expected_visibility FROM pg_policy WHERE polrelid=format('%I.ash_onetime_effect_outcomes',install_schema)::regclass AND polname='ash_onetime_claim_visibility';
    SELECT prosrc INTO STRICT routine_body FROM pg_proc WHERE oid=format('%I.ash_onetime_maintenance_policy_error()',routine_schema)::regprocedure;
    routine_body := replace(replace(routine_body,quote_literal('@policy_expression@'),quote_literal(expected_policy)),quote_literal('@visibility_expression@'),quote_literal(expected_visibility));
    -- rule:install-policy-invoker
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_policy_error() RETURNS text LANGUAGE plpgsql SECURITY INVOKER %s AS %L',routine_schema,routine_settings,routine_body);
    SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'name',p.proname,'arguments',p.proargtypes::text,
      'owner',p.proowner,'definer',p.prosecdef,'config',to_jsonb(p.proconfig),
      'identity',to_jsonb(p)-ARRAY['oid','pronamespace','proowner','proacl','prosrc','prosupport','proargdefaults','prosqlbody','pronargdefaults'],
      'executable',jsonb_build_object('support',p.prosupport,'default_count',p.pronargdefaults,'defaults',#{rq("ash_onetime_maintenance_normalize")}(p.proargdefaults::text,0::oid),'sqlbody',#{rq("ash_onetime_maintenance_normalize")}(p.prosqlbody::text,0::oid)),'digest',encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')))
    INTO manifest FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.pronamespace=routine_schema_oid
      AND p.oid IN (SELECT to_regprocedure(format('%I.%I(%s)',routine_schema,x->>'name',x->>'types')) FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x)
      AND p.proname<>'ash_onetime_maintenance_trust';
    SELECT prosrc INTO STRICT routine_body FROM pg_proc WHERE oid=format('%I.ash_onetime_maintenance_trust()',routine_schema)::regprocedure;
    routine_body := replace(routine_body,quote_literal('[]') || '::jsonb; -- @routine_manifest@',quote_literal(manifest::text) || '::jsonb;');
    -- rule:install-trust-invoker
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.ash_onetime_maintenance_trust() RETURNS void LANGUAGE plpgsql SECURITY INVOKER %s AS %L',routine_schema,routine_settings,routine_body);
    SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'name',p.proname,'arguments',p.proargtypes::text,
      'owner',p.proowner,'definer',p.prosecdef,'config',to_jsonb(p.proconfig),
      'identity',to_jsonb(p)-ARRAY['oid','pronamespace','proowner','proacl','prosrc','prosupport','proargdefaults','prosqlbody','pronargdefaults'],
      'executable',jsonb_build_object('support',p.prosupport,'default_count',p.pronargdefaults,'defaults',#{rq("ash_onetime_maintenance_normalize")}(p.proargdefaults::text,0::oid),'sqlbody',#{rq("ash_onetime_maintenance_normalize")}(p.prosqlbody::text,0::oid)),'digest',encode(sha256(convert_to(p.prosrc,'UTF8')),'hex')))
    INTO manifest FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.pronamespace=routine_schema_oid
      AND p.oid IN (SELECT to_regprocedure(format('%I.%I(%s)',routine_schema,x->>'name',x->>'types')) FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) x);
    EXECUTE format('UPDATE %I.ash_onetime_maintenance_runs SET last_counts=last_counts || jsonb_build_object(''routines'',$1) WHERE step=''install''',install_schema) USING manifest;
    PERFORM #{rq("ash_onetime_maintenance_lock")}(false::boolean,5000::integer);
    PERFORM #{rq("ash_onetime_maintenance_trust")}();
    PERFORM set_config('role',migrating_role,true);
  END
  """))
end

defp maintenance_literal(nil), do: "NULL"
defp maintenance_literal(value), do: "E'" <> (value |> String.replace("\\", "\\\\") |> String.replace("'", "''")) <> "'"

defp routine_schema_name do
  schema = @install_prefix || prefix() ||
    (repo().query!("SELECT n.nspname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=pg_catalog.to_regclass($1::text)", ["ash_onetime_response_payloads"]).rows |> hd() |> hd())
  "ash_onetime_" <> binary_part(Base.encode16(:crypto.hash(:sha256,schema),case: :lower),0,48)
end

defp rq(name), do: quote_identifier(routine_schema_name()) <> "." <> quote_identifier(name)
