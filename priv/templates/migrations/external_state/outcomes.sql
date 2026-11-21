<%= case fragment do %>
<% :ddl -> %>
CREATE TABLE @schema@.ash_onetime_effect_outcomes (
  @hash_columns@
  claim_id uuid NOT NULL,
  -- rule:outcomes-check-attempt
  attempt bigint NOT NULL CHECK (attempt >= 1),
  -- rule:outcomes-check-outcome
  outcome text NOT NULL CHECK (outcome IN ('held','absent_proven')),
  recorded_at timestamptz NOT NULL
  -- rule:outcomes-primary-key
  , PRIMARY KEY (@key_columns@claim_id, attempt)
  -- rule:fk-present
  , CONSTRAINT ash_onetime_effect_outcomes_claim_fkey FOREIGN KEY (@key_columns@claim_id)
    REFERENCES @schema@.ash_onetime_idempotency_claims (@key_columns@id)
    -- rule:fk-cascade
    ON DELETE CASCADE
  -- end-rule:fk-present
) @partitioning@
<% :guard_security -> %>
-- rule:outcome-guard-definer
DEFINER
<% :bound_security -> %>
-- rule:outcome-bound-invoker
INVOKER SET row_security = on
<% :bound_settings -> %>
-- rule:outcome-bound-search-path
SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD'
<% :guard_settings -> %>
-- rule:outcome-guard-search-path
-- rule:outcome-guard-row-security
SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = off
<% :visible_settings -> %>
-- rule:visibility-helper-search-path
-- rule:visibility-helper-settings
SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = on
<% :visible_acl -> %>
        -- rule:visibility-helper-public
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC',routine_oid::regprocedure);
<% :rls -> %>
      -- rule:outcome-rls-follows-claims
      IF (SELECT relforcerowsecurity FROM pg_class WHERE oid=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass) THEN
        EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',target.oid::regclass);
      END IF;
<% :guard -> %>
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- rule:outcome-guard-update
    RAISE EXCEPTION 'effect outcome records are immutable' USING ERRCODE='23514';
  ELSIF EXISTS (SELECT 1 FROM @schema@.ash_onetime_idempotency_claims c
    -- rule:outcome-guard-parent-lookup
    WHERE c.id=OLD.claim_id
      AND (to_jsonb(OLD)->>'operation_hash' IS NULL OR c.operation_hash=(to_jsonb(OLD)->>'operation_hash')::bytea)
      AND (to_jsonb(OLD)->>'logical_partition' IS NULL OR c.logical_partition=to_jsonb(OLD)->>'logical_partition')) THEN
    RAISE EXCEPTION 'effect outcome parent still exists' USING ERRCODE='23514';
  END IF;
  RETURN OLD;
END
<% :bound -> %>
DECLARE
  granted_attempt bigint;
BEGIN
  -- rule:outcome-bound-replica-trusted
  IF pg_catalog.current_setting('session_replication_role')='replica'
    AND pg_catalog.pg_has_role(current_user,(SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID),'SET') THEN
    RETURN NEW;
  END IF;
  SELECT c.effect_attempt INTO granted_attempt FROM @schema@.ash_onetime_idempotency_claims c
    WHERE c.id=NEW.claim_id
      AND (to_jsonb(NEW)->>'operation_hash' IS NULL OR c.operation_hash=(to_jsonb(NEW)->>'operation_hash')::bytea)
      AND (to_jsonb(NEW)->>'logical_partition' IS NULL OR c.logical_partition=to_jsonb(NEW)->>'logical_partition');
  -- rule:outcome-bound-attempt
  -- rule:outcome-bound-late
  IF NEW.attempt > granted_attempt THEN
    RAISE EXCEPTION 'effect outcome attempt was not granted' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END
<% :visible -> %>
SELECT EXISTS (SELECT 1 FROM @schema@.ash_onetime_idempotency_claims c
  WHERE c.id=$3 AND ($1 IS NULL OR c.operation_hash=$1)
    AND ($2 IS NULL OR c.logical_partition=$2))
<% :triggers -> %>
    EXECUTE format('CREATE TRIGGER ash_onetime_effect_outcome_guard BEFORE UPDATE OR DELETE ON %I.ash_onetime_effect_outcomes FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_guard_effect_outcome()',install_schema,routine_schema);
    -- rule:always-outcome-guard
    EXECUTE format('ALTER TABLE %I.ash_onetime_effect_outcomes ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_guard',install_schema);
    EXECUTE format('CREATE TRIGGER ash_onetime_effect_outcome_bound BEFORE INSERT ON %I.ash_onetime_effect_outcomes FOR EACH ROW EXECUTE FUNCTION %I.ash_onetime_bound_effect_outcome()',install_schema,routine_schema);
    -- rule:always-outcome-bound
    EXECUTE format('ALTER TABLE %I.ash_onetime_effect_outcomes ENABLE ALWAYS TRIGGER ash_onetime_effect_outcome_bound',install_schema);
<% :create -> %>
    DECLARE
      install_schema text;
      hash_claims boolean;
      owner_name text;
      migrating_role text := current_user;
      table_ddl text := <%= "#" <> "{maintenance_literal(" <> inspect(EEx.eval_file(__ENV__.file, fragment: :ddl)) <> ")}" %>;
      child record;
      bounds text[];
    BEGIN
      SELECT n.nspname,c.relkind='p',pg_get_userbyid(c.relowner) INTO STRICT install_schema,hash_claims,owner_name
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE c.oid=#{maintenance_literal(q("ash_onetime_idempotency_claims"))}::regclass;
      PERFORM set_config('role',owner_name,true);
      table_ddl := replace(replace(replace(replace(table_ddl,'@schema@',format('%I',install_schema)),
        '@hash_columns@',CASE WHEN hash_claims THEN 'operation_hash bytea NOT NULL, logical_partition text NOT NULL,' ELSE '' END),
        '@key_columns@',CASE WHEN hash_claims THEN 'operation_hash, logical_partition, ' ELSE '' END),
        '@partitioning@',CASE WHEN hash_claims THEN 'PARTITION BY HASH (operation_hash)' ELSE 'USING heap' END);
      EXECUTE table_ddl;
      IF hash_claims THEN
        FOR child IN SELECT c.relpartbound::text AS bound FROM pg_class c JOIN pg_inherits i ON i.inhrelid=c.oid
          WHERE i.inhparent=format('%I.ash_onetime_idempotency_claims',install_schema)::regclass LOOP
          bounds := regexp_match(child.bound,':modulus ([0-9]+) :remainder ([0-9]+)');
          EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.ash_onetime_effect_outcomes FOR VALUES WITH (MODULUS %s, REMAINDER %s) USING heap',
            install_schema,'ash_onetime_effect_outcomes_p' || bounds[2],install_schema,bounds[1]::integer,bounds[2]::integer);
        END LOOP;
      END IF;
      -- rule:external-outcomes-restore-role
      PERFORM set_config('role',migrating_role,true);
    END
<% end %>
