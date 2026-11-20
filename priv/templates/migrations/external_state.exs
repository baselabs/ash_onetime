<%
runtime_names = ~w(ash_onetime_cleanup_eligible ash_onetime_guard_idempotency_delete ash_onetime_guard_nonce_delete ash_onetime_guard_idempotency_update ash_onetime_guard_effect_outcome ash_onetime_bound_effect_outcome ash_onetime_claim_visible ash_onetime_maintenance_active ash_onetime_maintenance_reset_acl ash_onetime_expire_responses ash_onetime_cleanup_idempotency ash_onetime_cleanup_nonce ash_onetime_reap_idempotency)
historical_names = ~w(ash_onetime_maintenance_normalize ash_onetime_maintenance_shape ash_onetime_maintenance_reference)
hold_source = File.read!(Path.join(__DIR__, "operation_hold.exs"))
[_, previous_functions] = Regex.run(~r/(  defp install_hold_functions do\n.*?)(?=  defp install_previous_functions do)/s, hold_source)
previous_functions = String.replace(previous_functions, "defp install_hold_functions", "defp restore_previous_functions")
%>
defmodule <%= inspect(module) %> do
  use Ecto.Migration
  @install_prefix <%= inspect(install_prefix) %>
  @abandonment_floor_seconds 86_400
  @claims "ash_onetime_idempotency_claims"
  @external_functions <%= EEx.eval_file(Path.join(__DIR__, "maintenance_routines.exs"), only: runtime_names, maintenance: false) |> String.trim() %>
  @historical_functions <%= EEx.eval_file(Path.join(__DIR__, "maintenance_routines.exs"), only: historical_names, maintenance: false, reference_legacy: true) |> String.trim() %>

  def up do
    execute("DO " <> maintenance_literal("""
    DECLARE
      install_schema text;
      owner_oid oid;
      routine_schema text;
      scratch_schema text;
      owner_name text;
      target record;
      routine jsonb;
      routine_body text;
      manifest jsonb;
      legacy_shapes jsonb;
      actual_shape jsonb;
      expected_shape jsonb;
      historical_shape jsonb;
      shape_key text;
      historical_key boolean;
      primary_constraint text;
      check_ddl record;
      force_claims boolean;
    BEGIN
      PERFORM set_config('lock_timeout','5s',true);
      SELECT n.nspname,c.relowner INTO STRICT install_schema,owner_oid FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=#{maintenance_literal(q(@claims))}::regclass;
      owner_name := pg_get_userbyid(owner_oid);
      PERFORM set_config('role',owner_name,true);
      FOR target IN WITH RECURSIVE relations(oid) AS (
        SELECT c.oid FROM pg_class c WHERE c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=install_schema)
          AND (c.relname IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_response_payloads')
            OR EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
              WHERE t.tgrelid=c.oid AND p.proname='ash_onetime_fact_append_only'))
        UNION SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON r.oid=i.inhparent
      ) SELECT oid FROM relations ORDER BY oid LOOP
        EXECUTE format('LOCK TABLE ONLY %s IN ACCESS EXCLUSIVE MODE',target.oid::regclass);
      END LOOP;
      PERFORM set_config('row_security','off',true);
      IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=#{maintenance_literal(q(@claims))}::regclass
        AND attname='hold_reference' AND NOT attisdropped) THEN
        -- rule:external-hold-required
        RAISE EXCEPTION 'operation_hold_required: apply operation-hold before external-state';
      END IF;
      CREATE TEMP TABLE ash_onetime_upgrade_scratch(value integer) ON COMMIT DROP;
      SELECT nspname INTO STRICT scratch_schema FROM pg_namespace WHERE oid=pg_my_temp_schema();
      FOR routine IN SELECT * FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@historical_functions))}::jsonb) LOOP
        routine_body := replace(replace(replace(replace(routine->>'body',
          '@schema@',format('%I',install_schema)),
          '@schema_name@',quote_literal(install_schema)), '@routines@',format('%I',scratch_schema)),
          '@routine_schema_name@',quote_literal(install_schema));
        EXECUTE format('CREATE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE plpgsql
          -- rule:external-reference-invoker
          SECURITY INVOKER
          -- rule:external-reference-search-path
          SET search_path=pg_catalog,pg_temp AS %L',
          scratch_schema,routine->>'name',routine->>'args',routine->>'result',routine_body);
      END LOOP;
      EXECUTE format('SELECT %I.ash_onetime_maintenance_reference(false)',scratch_schema) INTO manifest;
      EXECUTE format('SELECT %I.ash_onetime_maintenance_reference(true)',scratch_schema) INTO legacy_shapes;
      FOR target IN WITH RECURSIVE relations(oid) AS (
        SELECT c.oid FROM pg_class c WHERE c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=install_schema)
          AND c.relname IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_response_payloads')
        UNION SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON r.oid=i.inhparent
      ) SELECT c.oid,c.relname,p.relname AS parent_name FROM relations r JOIN pg_class c USING(oid)
        LEFT JOIN pg_inherits i ON i.inhrelid=c.oid LEFT JOIN pg_class p ON p.oid=i.inhparent
      LOOP
        shape_key := coalesce(target.parent_name,target.relname) || CASE WHEN target.parent_name IS NULL THEN '' ELSE '_child' END;
        expected_shape := manifest->shape_key;
        historical_shape := legacy_shapes->shape_key;
        EXECUTE format('SELECT %I.ash_onetime_maintenance_shape($1)',scratch_schema) INTO actual_shape USING target.oid;
        IF actual_shape-'constraints' IS DISTINCT FROM expected_shape-'constraints' THEN
          historical_shape := legacy_shapes->(coalesce(target.parent_name,target.relname) || '_logical_upgrade' || CASE WHEN target.parent_name IS NULL THEN '' ELSE '_child' END);
        END IF;
        -- rule:upgrade-shape-authentication
        IF expected_shape IS NULL OR historical_shape IS NULL
          OR (actual_shape-'constraints' IS DISTINCT FROM expected_shape-'constraints'
            AND actual_shape-'constraints' IS DISTINCT FROM historical_shape-'constraints')
          -- rule:maintenance-upgrade-constraint-count
          OR jsonb_array_length(actual_shape->'constraints')<>jsonb_array_length(expected_shape->'constraints')
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(actual_shape->'constraints') x
            WHERE NOT (expected_shape->'constraints') @> jsonb_build_array(x)
              AND NOT (historical_shape->'constraints') @> jsonb_build_array(x))
          -- rule:maintenance-upgrade-constraint-coverage
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(expected_shape->'constraints') e
            WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(actual_shape->'constraints') x
              WHERE x=e OR ((historical_shape->'constraints') @> jsonb_build_array(x)
                AND (x-'expression'=e-'expression' OR (x->>'type'='p' AND e->>'type'='p'))))) THEN
          RAISE EXCEPTION 'untrusted_dependency: upgrade relation shape %',target.relname USING DETAIL=jsonb_build_object('actual',actual_shape,'expected',expected_shape,'historical',historical_shape)::text;
        END IF;
        -- end-rule:upgrade-shape-authentication
      END LOOP;
      FOR target IN SELECT c.oid,c.relname FROM pg_class c WHERE c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=install_schema)
        AND c.relname IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_response_payloads') LOOP
        EXECUTE format('SELECT %I.ash_onetime_maintenance_shape($1)',scratch_schema) INTO actual_shape USING target.oid;
        expected_shape := manifest->target.relname;
        historical_key := actual_shape->'indexes' IS DISTINCT FROM expected_shape->'indexes';
        IF actual_shape IS DISTINCT FROM expected_shape THEN
          -- rule:maintenance-upgrade-check-names
          FOR check_ddl IN SELECT conname AS name FROM pg_constraint WHERE conrelid=target.oid AND contype='c' LOOP
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',target.oid::regclass,check_ddl.name);
          END LOOP;
          FOR check_ddl IN SELECT key,value FROM jsonb_each_text(manifest->(target.relname || '_check_ddl')) LOOP
            EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s',target.oid::regclass,check_ddl.key,check_ddl.value);
          END LOOP;
          -- rule:upgrade-legacy-keys
          -- rule:maintenance-logical-primary
          IF historical_key THEN
            SELECT conname INTO STRICT primary_constraint FROM pg_constraint WHERE conrelid=target.oid AND contype='p';
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',target.oid::regclass,primary_constraint);
            EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s',target.oid::regclass,primary_constraint,manifest->>(target.relname || '_primary_ddl'));
          END IF;
        END IF;
      END LOOP;
      FOR routine IN SELECT * FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@historical_functions))}::jsonb) LOOP
        EXECUTE format('DROP FUNCTION %I.%I(%s)',scratch_schema,routine->>'name',routine->>'types');
      END LOOP;
      FOR check_ddl IN SELECT k.conname FROM pg_constraint k WHERE k.conrelid=#{maintenance_literal(q(@claims))}::regclass
        AND k.contype='c' AND k.conkey @> ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid=k.conrelid AND attname='response_partition')]::smallint[] LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',#{maintenance_literal(q(@claims))}::regclass,check_ddl.conname);
      END LOOP;
      ALTER TABLE #{q(@claims)} ADD COLUMN effect_local boolean NOT NULL DEFAULT false,
        ADD COLUMN effect_attempt bigint NOT NULL DEFAULT 0,
        ADD COLUMN response_retain_until timestamptz, ADD COLUMN response_expired_at timestamptz;
      SELECT relforcerowsecurity INTO STRICT force_claims FROM pg_class WHERE oid=#{maintenance_literal(q(@claims))}::regclass;
      IF force_claims THEN ALTER TABLE #{q(@claims)} NO FORCE ROW LEVEL SECURITY; END IF;
      UPDATE #{q(@claims)} SET response_retain_until=retain_until;
      IF force_claims THEN ALTER TABLE #{q(@claims)} FORCE ROW LEVEL SECURITY; END IF;
      ALTER TABLE #{q(@claims)} ALTER COLUMN response_retain_until SET NOT NULL;
      ALTER TABLE #{q(@claims)} ADD <%= EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: :checks) |> String.trim() |> String.replace(",\n-- rule:", ", ADD\n-- rule:") %>;
    END
    """))
    flush()
    execute("DO " <> maintenance_literal("""
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :create) %>
    """))
    install_external_functions()
  end

  def down do
    execute("DO " <> maintenance_literal("""
    DECLARE target record;
    BEGIN
      PERFORM set_config('lock_timeout','5s',true);
      -- rule:rollback-lock-external-state
      LOCK TABLE #{q(@claims)}, #{q("ash_onetime_effect_outcomes")} IN ACCESS EXCLUSIVE MODE;
      PERFORM set_config('row_security','off',true);
      -- rule:rollback-refusal-external-state
      IF EXISTS (SELECT 1 FROM #{q(@claims)} WHERE state='processing' AND NOT effect_local) THEN
        RAISE EXCEPTION 'unresolved external claims prevent rollback' USING ERRCODE='23514';
      END IF;
      -- rule:rollback-refusal-expired
      IF EXISTS (SELECT 1 FROM #{q(@claims)} WHERE response_expired_at IS NOT NULL) THEN
        RAISE EXCEPTION 'expired responses prevent rollback' USING ERRCODE='23514';
      END IF;
      FOR target IN WITH RECURSIVE relations(oid) AS (
        SELECT unnest(ARRAY[#{maintenance_literal(q(@claims))}::regclass::oid,
          #{maintenance_literal(q("ash_onetime_nonce_claims"))}::regclass::oid,
          #{maintenance_literal(q("ash_onetime_response_payloads"))}::regclass::oid])
        UNION SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON r.oid=i.inhparent
      ) SELECT oid FROM relations LOOP
        EXECUTE format('DROP POLICY ash_onetime_maintenance ON %s',target.oid::regclass);
      END LOOP;
      DROP TRIGGER ash_onetime_idempotency_update_guard ON #{q(@claims)};
      DROP TABLE #{q("ash_onetime_effect_outcomes")} CASCADE;
      ALTER TABLE #{q(@claims)} DROP COLUMN effect_local, DROP COLUMN effect_attempt,
        DROP COLUMN response_retain_until, DROP COLUMN response_expired_at;
      ALTER TABLE #{q(@claims)} ADD <%= EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: :legacy_checks) %>;
    END
    """))
    restore_previous_functions()
    for name <- ~w(ash_onetime_guard_idempotency_update ash_onetime_guard_effect_outcome ash_onetime_bound_effect_outcome ash_onetime_claim_visible ash_onetime_expire_responses ash_onetime_maintenance_active ash_onetime_maintenance_reset_acl) do
      routine = Enum.find(@external_functions, &(&1.name == name))
      execute("DROP FUNCTION #{q(name)}(#{routine.types})")
    end
  end

  defp install_external_functions do
    execute("DO " <> maintenance_literal("""
    DECLARE
      install_schema text;
      routine_schema text;
      owner_oid oid;
      owner_name text;
      routine jsonb;
      routine_body text;
      routine_oid oid;
      grantee oid;
      target record;
    BEGIN
      SELECT n.nspname,c.relowner INTO STRICT install_schema,owner_oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE c.oid=#{maintenance_literal(q(@claims))}::regclass;
      routine_schema := install_schema;
      owner_name := pg_get_userbyid(owner_oid);
      FOR routine IN SELECT * FROM jsonb_array_elements(#{maintenance_literal(Jason.encode!(@external_functions))}::jsonb) LOOP
        routine_body := replace(replace(replace(replace(replace(routine->>'body', '@schema@',format('%I',install_schema)),
          '@routines@',format('%I',routine_schema)), '@schema_name@',quote_literal(install_schema)), '@owner@',owner_oid::text),
          '@outcomes@',quote_literal(format('%I.ash_onetime_effect_outcomes',install_schema)));
        routine_body := replace(replace(replace(routine_body,'@payload@',quote_literal(format('%I.ash_onetime_response_payloads',install_schema))),
          '@idempotency@',quote_literal(format('%I.ash_onetime_idempotency_claims',install_schema))),
          '@nonce@',quote_literal(format('%I.ash_onetime_nonce_claims',install_schema)));
        -- rule:external-routine-security
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE %s %s SECURITY %s %s AS %L',
          routine_schema,routine->>'name',routine->>'args',routine->>'result',routine->>'language',
          CASE WHEN routine->>'language'='sql' THEN 'STABLE' ELSE 'VOLATILE' END, routine->>'security',
          routine->>'settings',routine_body);
        routine_oid := to_regprocedure(format('%I.%I(%s)',routine_schema,routine->>'name',routine->>'types'));
        FOR grantee IN SELECT DISTINCT a.grantee FROM pg_proc p,LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
          WHERE p.oid=routine_oid AND a.grantee<>owner_oid LOOP
          EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s CASCADE',routine_oid::regprocedure,CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);
        END LOOP;
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',routine_oid::regprocedure,owner_name);
        IF routine->>'grant_class' IN ('step','public_invoker') OR routine->>'name'='ash_onetime_cleanup_eligible' THEN
          EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC',routine_oid::regprocedure);
        END IF;
      END LOOP;
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "claims.sql"]), fragment: :trigger_attachment) %>
      <%= EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :triggers) %>
      FOR target IN WITH RECURSIVE relations(oid) AS (
        SELECT c.oid FROM pg_class c WHERE c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=install_schema)
          AND c.relname IN ('ash_onetime_idempotency_claims','ash_onetime_nonce_claims','ash_onetime_response_payloads','ash_onetime_effect_outcomes')
        UNION SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON r.oid=i.inhparent
      ) SELECT oid FROM relations LOOP
        EXECUTE format('
        -- rule:external-maintenance-policy
        CREATE POLICY ash_onetime_maintenance ON %s AS PERMISSIVE FOR ALL TO %I USING (%I.ash_onetime_maintenance_active())
        -- rule:external-maintenance-check
        WITH CHECK (%I.ash_onetime_maintenance_active())',target.oid::regclass,owner_name,routine_schema,routine_schema);
      END LOOP;
      FOR target IN WITH RECURSIVE outcomes(oid) AS (
        SELECT format('%I.ash_onetime_effect_outcomes',install_schema)::regclass::oid
        UNION SELECT i.inhrelid FROM pg_inherits i JOIN outcomes o ON o.oid=i.inhparent
      ) SELECT oid FROM outcomes LOOP
        PERFORM #{q("ash_onetime_maintenance_reset_acl")}(target.oid,false);
        EXECUTE format('
        -- rule:external-claim-visibility-policy
        CREATE POLICY ash_onetime_claim_visibility ON %s AS PERMISSIVE FOR ALL TO PUBLIC USING (%I.ash_onetime_claim_visible(%sclaim_id))
        -- rule:external-claim-visibility-check
        WITH CHECK (%I.ash_onetime_claim_visible(%sclaim_id))',
          target.oid::regclass,routine_schema,CASE WHEN (SELECT relkind FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass)='p' THEN 'operation_hash,logical_partition,' ELSE 'NULL::bytea,NULL::text,' END,
          routine_schema,CASE WHEN (SELECT relkind FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass)='p' THEN 'operation_hash,logical_partition,' ELSE 'NULL::bytea,NULL::text,' END);
        IF (SELECT relrowsecurity FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass) THEN
          EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',target.oid::regclass);
        END IF;
        <%= EEx.eval_file(Path.join([__DIR__, "external_state", "outcomes.sql"]), fragment: :rls) %>
      END LOOP;
    END
    """))
  end

<%= previous_functions %>
  defp q(name) do
    case @install_prefix || prefix() do
      nil -> qi(name)
      schema -> qi(schema) <> "." <> qi(name)
    end
  end
  defp qi(value), do: ~s("#{String.replace(value,"\"","\"\"")}")
  defp maintenance_literal(value), do: "E'" <> (value |> String.replace("\\", "\\\\") |> String.replace("'", "''")) <> "'"
end
