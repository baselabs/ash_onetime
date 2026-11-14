defmodule <%= inspect(module) %> do
  use Ecto.Migration

  @install_prefix <%= inspect(install_prefix) %>
  <%= EEx.eval_file(Path.join(__DIR__, "maintenance_helpers.exs"), binding()) %>

  def up, do: install_maintenance()

  def down do
    execute("DO " <> maintenance_literal("""
    DECLARE
      original jsonb;
      original_acls jsonb;
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
      SELECT pg_get_userbyid(c.relowner),n.nspname INTO STRICT owner_name,install_schema FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.oid=#{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass;
      routine_schema := 'ash_onetime_' || substr(encode(sha256(convert_to(install_schema,'UTF8')),'hex'),1,48);
      PERFORM set_config('role',owner_name,true);
      SELECT last_counts->'previous_functions',last_counts->'previous_acls' INTO original,original_acls
      FROM #{q("ash_onetime_maintenance_runs")} WHERE step='install';
      FOR relation_oid IN SELECT #{rq("ash_onetime_maintenance_relations")}() LOOP
        EXECUTE format('DROP POLICY IF EXISTS ash_onetime_maintenance ON %s',relation_oid::regclass);
        PERFORM #{rq("ash_onetime_maintenance_reset_acl")}(relation_oid,true);
      END LOOP;
      PERFORM set_config('role',migrating_role,true);
      -- Recreate each invoker as its original owner. This works with SET
      -- membership and NO INHERIT, without requiring reverse membership.
      PERFORM set_config('role',owner_name,true);
      EXECUTE format('DROP TRIGGER ash_onetime_idempotency_delete_guard ON %s',#{maintenance_literal(q("ash_onetime_idempotency_claims"))}::regclass);
      EXECUTE format('DROP TRIGGER ash_onetime_nonce_delete_guard ON %s',#{maintenance_literal(q("ash_onetime_nonce_claims"))}::regclass);
      FOR item IN SELECT * FROM jsonb_array_elements(original) LOOP
        EXECUTE format('DROP FUNCTION %s',(item->>'oid')::oid::regprocedure);
      END LOOP;
      FOR item IN SELECT * FROM jsonb_array_elements(original) LOOP
        PERFORM set_config('role',item->>'owner',true);
        EXECUTE item->>'definition';
      END LOOP;
      PERFORM set_config('role',owner_name,true);
      EXECUTE format('CREATE TRIGGER ash_onetime_idempotency_delete_guard BEFORE DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_idempotency_delete()',#{maintenance_literal(q("ash_onetime_idempotency_claims"))}::regclass,#{maintenance_literal(@install_prefix || prefix() || "public")});
      EXECUTE format('CREATE TRIGGER ash_onetime_nonce_delete_guard BEFORE DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_nonce_delete()',#{maintenance_literal(q("ash_onetime_nonce_claims"))}::regclass,#{maintenance_literal(@install_prefix || prefix() || "public")});
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
      FOR routine IN SELECT * FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@maintenance_functions))}::jsonb)
        WHERE value->>'name' NOT IN ('ash_onetime_cleanup_eligible','ash_onetime_guard_idempotency_delete',
          'ash_onetime_guard_nonce_delete','ash_onetime_cleanup_idempotency','ash_onetime_cleanup_nonce','ash_onetime_reap_idempotency')
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
