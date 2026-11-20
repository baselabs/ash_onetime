defmodule <%= inspect(module) %> do
  use Ecto.Migration

  @install_prefix <%= inspect(install_prefix) %>
  <%= EEx.eval_file(Path.join(__DIR__, "maintenance_helpers.exs"), binding()) %>

  def up, do: install_maintenance(:upgrade)

  def down do
    execute("DO " <> maintenance_literal("""
    DECLARE
      original jsonb;
      original_acls jsonb;
      original_triggers jsonb;
      original_policies jsonb;
      dependency jsonb;
      item jsonb;
      privilege jsonb;
      target text;
      grantee oid;
      migrating_role text := current_user;
      owner_name text;
      relation_oid oid;
      install_schema text;
      routine_schema text;
      routine jsonb;
      column_name text;
    BEGIN
      PERFORM set_config('lock_timeout','5s',true);
      SELECT pg_get_userbyid(c.relowner),n.nspname INTO STRICT owner_name,install_schema FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid=#{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass;
      routine_schema := 'ash_onetime_' || substr(encode(sha256(convert_to(install_schema,'UTF8')),'hex'),1,48);
      PERFORM set_config('role',owner_name,true);
      -- rule:rollback-lock-maintenance
      LOCK TABLE #{q("ash_onetime_idempotency_claims")}, #{q("ash_onetime_effect_outcomes")} IN ACCESS EXCLUSIVE MODE;
      PERFORM set_config('row_security','off',true);
      -- rule:rollback-refusal-maintenance
      IF EXISTS (SELECT 1 FROM #{q("ash_onetime_idempotency_claims")} WHERE state='processing' AND NOT effect_local) THEN
        RAISE EXCEPTION 'unresolved external claims prevent rollback' USING ERRCODE='23514';
      END IF;
      SELECT last_counts->'previous_functions',last_counts->'previous_acls' INTO original,original_acls
      FROM #{q("ash_onetime_maintenance_runs")} WHERE step='install';
      FOR relation_oid IN SELECT #{rq("ash_onetime_maintenance_relations")}() LOOP
        PERFORM #{rq("ash_onetime_maintenance_reset_acl")}(relation_oid,true);
      END LOOP;
      PERFORM set_config('role',migrating_role,true);
      -- Move every original function before taking native trigger and policy
      -- definitions, so their references name the restored schema.
      PERFORM set_config('role',owner_name,true);
      FOR item IN SELECT * FROM jsonb_array_elements(original) LOOP
        EXECUTE format('ALTER FUNCTION %s SET SCHEMA %I',(item->>'oid')::oid::regprocedure,install_schema);
      END LOOP;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(original) old WHERE old->>'owner'<>owner_name) THEN
        -- SET membership does not let the owner transfer a function back to
        -- the migrator. Recreate it as its recorded owner instead. The parent
        -- locks keep the restored guards and policies atomic with the refusal.
        SELECT coalesce(jsonb_agg(jsonb_build_object('relation',t.tgrelid,'name',t.tgname,
          'definition',pg_get_triggerdef(t.oid),'enabled',t.tgenabled)),'[]')
        INTO original_triggers FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgparentid=0
          AND t.tgfoid IN (SELECT (old->>'oid')::oid FROM jsonb_array_elements(original) old);
        SELECT coalesce(jsonb_agg(jsonb_build_object('relation',p.polrelid,'name',p.polname,
          -- rule:rollback-policy-permissive
          'definition',format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s',
            p.polname,p.polrelid::regclass,CASE WHEN p.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
            CASE p.polcmd WHEN '*' THEN 'ALL' WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT'
              WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END,
            (SELECT string_agg(CASE WHEN role_oid=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(role_oid)) END,',') FROM unnest(p.polroles) role_oid),
            CASE WHEN p.polqual IS NULL THEN '' ELSE format(' USING (%s)',pg_get_expr(p.polqual,p.polrelid)) END,
            -- rule:rollback-policy-check
            CASE WHEN p.polwithcheck IS NULL THEN '' ELSE format(' WITH CHECK (%s)',pg_get_expr(p.polwithcheck,p.polrelid)) END))),'[]')
        INTO original_policies FROM pg_policy p WHERE EXISTS (
          SELECT 1 FROM pg_depend d WHERE d.classid='pg_policy'::regclass AND d.objid=p.oid
            AND d.refclassid='pg_proc'::regclass
            AND d.refobjid IN (SELECT (old->>'oid')::oid FROM jsonb_array_elements(original) old));
        FOR dependency IN SELECT * FROM jsonb_array_elements(original_policies) LOOP
          EXECUTE format('DROP POLICY %I ON %s',dependency->>'name',(dependency->>'relation')::oid::regclass);
        END LOOP;
        FOR dependency IN SELECT * FROM jsonb_array_elements(original_triggers) LOOP
          EXECUTE format('DROP TRIGGER %I ON %s',dependency->>'name',(dependency->>'relation')::oid::regclass);
        END LOOP;
        FOR item IN SELECT * FROM jsonb_array_elements(original) LOOP
          EXECUTE format('DROP FUNCTION %s',(item->>'oid')::oid::regprocedure);
        END LOOP;
      ELSE
        original_triggers := '[]';
        original_policies := '[]';
      END IF;
      FOR item IN SELECT * FROM jsonb_array_elements(original) LOOP
        PERFORM set_config('role',item->>'owner',true);
        EXECUTE item->>'definition';
      END LOOP;
      PERFORM set_config('role',owner_name,true);
      FOR dependency IN SELECT * FROM jsonb_array_elements(original_triggers) LOOP
        EXECUTE dependency->>'definition';
        EXECUTE format('ALTER TABLE %s %s TRIGGER %I',(dependency->>'relation')::oid::regclass,
          CASE dependency->>'enabled' WHEN 'A' THEN 'ENABLE ALWAYS' WHEN 'R' THEN 'ENABLE REPLICA'
            WHEN 'D' THEN 'DISABLE' ELSE 'ENABLE' END,dependency->>'name');
      END LOOP;
      -- rule:M-firing-down-claims
      -- rule:M-firing-down-nonce
      -- Restored trigger firing modes are part of the rollback contract.
      FOR dependency IN SELECT * FROM jsonb_array_elements(original_policies) LOOP
        EXECUTE dependency->>'definition';
      END LOOP;
      PERFORM set_config('role',owner_name,true);
      FOR item IN SELECT * FROM jsonb_array_elements(original_acls) LOOP
        PERFORM set_config('role',pg_get_userbyid((item->>'owner')::oid),true);
        IF item->>'kind'='function' THEN
          SELECT jsonb_set(item,ARRAY['oid'],to_jsonb((o->>'identity')::regprocedure::oid)) INTO item
            FROM jsonb_array_elements(original) o WHERE o->>'oid'=item->>'oid';
          target := format('FUNCTION %s',(item->>'oid')::oid::regprocedure);
          FOR grantee IN SELECT DISTINCT a.grantee FROM pg_proc p,
            LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
            WHERE p.oid=(item->>'oid')::oid LOOP
            EXECUTE format('REVOKE ALL PRIVILEGES ON %s FROM %s CASCADE',target,
              CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);
          END LOOP;
        ELSIF item->>'kind'='column' THEN
          SELECT format('TABLE %s',(item->>'oid')::oid::regclass),attname INTO target,column_name
          FROM pg_attribute WHERE attrelid=(item->>'oid')::oid AND attnum=(item->>'column')::smallint;
        ELSE
          target := format('TABLE %s',(item->>'oid')::oid::regclass);
        END IF;
        FOR privilege IN
          WITH RECURSIVE grant_paths(role_oid,privilege_name,depth,path) AS (
            SELECT (item->>'owner')::oid,g->>'privilege',0,ARRAY[(item->>'owner')::oid]
            FROM jsonb_array_elements(item->'grants') g
            UNION ALL
            SELECT (g->>'grantee')::oid,p.privilege_name,p.depth+1,p.path || (g->>'grantee')::oid
            FROM grant_paths p JOIN jsonb_array_elements(item->'grants') g
              ON (g->>'grantor')::oid=p.role_oid AND g->>'privilege'=p.privilege_name
            WHERE (g->>'grantable')::boolean AND NOT (g->>'grantee')::oid=ANY(p.path)
          ) SELECT g FROM jsonb_array_elements(item->'grants') g
            ORDER BY (SELECT min(depth) FROM grant_paths p WHERE p.role_oid=(g->>'grantor')::oid
              AND p.privilege_name=g->>'privilege') NULLS LAST
        LOOP
          PERFORM set_config('role',pg_get_userbyid((privilege->>'grantor')::oid),true);
          EXECUTE format('GRANT %s%s ON %s TO %s%s',privilege->>'privilege',
            CASE WHEN item->>'kind'='column' THEN format(' (%I)',column_name) ELSE '' END,target,
            CASE WHEN (privilege->>'grantee')::oid=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid((privilege->>'grantee')::oid)) END,
            CASE WHEN (privilege->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
      END LOOP;
      PERFORM set_config('role',owner_name,true);
      EXECUTE format('DROP TABLE %I.ash_onetime_maintenance_runs',install_schema);
      FOR routine IN SELECT f.value FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb) AS f(value)
        WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(original) old WHERE
          to_regprocedure(old->>'identity')=to_regprocedure(format('%I.%I(%s)',install_schema,f.value->>'name',f.value->>'types')))
      LOOP
        EXECUTE format('DROP FUNCTION %I.%I(%s)',routine_schema,routine->>'name',routine->>'args');
      END LOOP;
      EXECUTE format('DROP SCHEMA %I',routine_schema);
      PERFORM set_config('role',migrating_role,true);
    END
    """))
  end

  defp q(name) do
    case @install_prefix || prefix() do
      nil -> quote_identifier(name)
      schema -> quote_identifier(schema) <> "." <> quote_identifier(name)
    end
  end
  defp quote_identifier(value), do: ~s("#{String.replace(value,"\"","\"\"")}")
end
