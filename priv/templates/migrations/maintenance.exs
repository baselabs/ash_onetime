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
    BEGIN
      SELECT last_counts->'previous_functions',last_counts->'previous_acls' INTO original,original_acls
      FROM #{q("ash_onetime_maintenance_runs")} WHERE step='install';
      SELECT pg_get_userbyid(relowner) INTO STRICT owner_name FROM pg_class
      WHERE oid=#{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass;
      PERFORM set_config('role',owner_name,true);
      FOR relation_oid IN SELECT #{q("ash_onetime_maintenance_relations")}() LOOP
        EXECUTE format('DROP POLICY IF EXISTS ash_onetime_maintenance ON %s',relation_oid::regclass);
        PERFORM #{q("ash_onetime_maintenance_reset_acl")}(relation_oid,true);
      END LOOP;
      PERFORM set_config('role',migrating_role,true);
      FOR item IN SELECT * FROM jsonb_array_elements(original) LOOP
        EXECUTE item->>'definition';
      END LOOP;
      FOR item IN SELECT * FROM jsonb_array_elements(original_acls) LOOP
        PERFORM set_config('role',pg_get_userbyid((item->>'owner')::oid),true);
        IF item->>'kind'='function' THEN
          target := format('FUNCTION %s',(item->>'oid')::oid::regprocedure);
          FOR grantee IN SELECT DISTINCT a.grantee FROM pg_proc p,
            LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
            WHERE p.oid=(item->>'oid')::oid LOOP
            EXECUTE format('REVOKE ALL PRIVILEGES ON %s FROM %s CASCADE',target,
              CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);
          END LOOP;
        ELSIF item->>'kind'='column' THEN
          SELECT format('TABLE %s',(item->>'oid')::oid::regclass),attname INTO target,owner_name
          FROM pg_attribute WHERE attrelid=(item->>'oid')::oid AND attnum=(item->>'column')::smallint;
        ELSE
          target := format('TABLE %s',(item->>'oid')::oid::regclass);
        END IF;
        FOR privilege IN SELECT * FROM jsonb_array_elements(item->'grants') LOOP
          EXECUTE format('GRANT %s%s ON %s TO %s%s',privilege->>'privilege',
            CASE WHEN item->>'kind'='column' THEN format(' (%I)',owner_name) ELSE '' END,target,
            CASE WHEN (privilege->>'grantee')::oid=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid((privilege->>'grantee')::oid)) END,
            CASE WHEN (privilege->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END);
        END LOOP;
      END LOOP;
      PERFORM set_config('role',migrating_role,true);
    END
    """))
    flush()
    execute("DROP TABLE #{q("ash_onetime_maintenance_runs")}")
    for routine <- @maintenance_functions,
        routine.name not in ["ash_onetime_cleanup_eligible", "ash_onetime_guard_idempotency_delete",
          "ash_onetime_guard_nonce_delete", "ash_onetime_cleanup_idempotency", "ash_onetime_cleanup_nonce", "ash_onetime_reap_idempotency"] do
      execute("DROP FUNCTION #{q(routine.name)}(#{routine.args})")
    end
  end

  defp q(name) do
    case @install_prefix || prefix() do
      nil -> quote_identifier(name)
      schema -> quote_identifier(schema) <> "." <> quote_identifier(name)
    end
  end
  defp quote_identifier(value), do: ~s("#{String.replace(value,"\"","\"\"")}")
end
