DECLARE
  node record;
  proc_row record;
  expected jsonb;
  manifest jsonb := '[]'::jsonb; -- @routine_manifest@
  relation_ids oid[];
  bad record;
BEGIN
  SELECT array_agg(r) INTO relation_ids FROM @schema@.ash_onetime_maintenance_relations() r;
  IF jsonb_array_length(manifest)=0 THEN RAISE EXCEPTION 'untrusted_dependency: package manifest'; END IF;

  SELECT t.tgname, t.tgrelid::regclass AS relation INTO bad FROM pg_trigger t
  WHERE t.tgrelid=ANY(relation_ids) AND NOT (
    (t.tgname='ash_onetime_idempotency_delete_guard'
     AND t.tgfoid=format('%I.ash_onetime_guard_idempotency_delete()',@schema_name@)::regprocedure
     AND (t.tgrelid=@idempotency@::regclass OR EXISTS (
       SELECT 1 FROM pg_inherits WHERE inhrelid=t.tgrelid AND inhparent=@idempotency@::regclass)))
    OR (t.tgname='ash_onetime_nonce_delete_guard'
     AND t.tgfoid=format('%I.ash_onetime_guard_nonce_delete()',@schema_name@)::regprocedure
     AND (t.tgrelid=@nonce@::regclass OR EXISTS (
       SELECT 1 FROM pg_inherits WHERE inhrelid=t.tgrelid AND inhparent=@nonce@::regclass)))
  ) LIMIT 1;
  IF FOUND THEN RAISE EXCEPTION 'untrusted_dependency: trigger %.%', bad.relation,bad.tgname; END IF;
  SELECT rulename, ev_class::regclass AS relation INTO bad FROM pg_rewrite WHERE ev_class=ANY(relation_ids) LIMIT 1;
  IF FOUND THEN RAISE EXCEPTION 'untrusted_dependency: rule %.%', bad.relation,bad.rulename; END IF;

  FOR node IN
    WITH RECURSIVE walk(classid,objectid) AS (
      SELECT 'pg_class'::regclass::oid, r FROM unnest(relation_ids) r
      UNION
      SELECT e.classid,e.objectid FROM walk w
      CROSS JOIN LATERAL @schema@.ash_onetime_maintenance_edges(w.classid,w.objectid) e
      WHERE e.objectid<>0
    ) SELECT * FROM walk
  LOOP
    IF node.classid='pg_proc'::regclass THEN
      SELECT p.*, n.nspname, r.rolsuper INTO STRICT proc_row
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_roles r ON r.oid=p.proowner
      WHERE p.oid=node.objectid;
      IF node.objectid < 16384 OR proc_row.rolsuper THEN CONTINUE; END IF;
      SELECT m INTO expected FROM jsonb_array_elements(manifest) m
      WHERE m->>'schema'=proc_row.nspname AND m->>'name'=proc_row.proname
        AND m->>'arguments'=proc_row.proargtypes::text
        AND (m->>'owner')::oid=proc_row.proowner
        AND (m->>'definer')::boolean=proc_row.prosecdef
        AND m->'config'=to_jsonb(proc_row.proconfig)
        AND m->>'digest'=encode(sha256(convert_to(proc_row.prosrc,'UTF8')),'hex');
      IF expected IS NULL THEN
        RAISE EXCEPTION 'untrusted_dependency: routine %', node.objectid::regprocedure;
      END IF;
    ELSIF node.classid='pg_type'::regclass AND node.objectid >= 16384 THEN
      IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_roles r ON r.oid=t.typowner
        WHERE t.oid=node.objectid AND NOT r.rolsuper
          AND NOT (t.typrelid=ANY(relation_ids))
          AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid=ANY(relation_ids) AND c.reltype=t.typelem)) THEN
        RAISE EXCEPTION 'untrusted_dependency: type %',node.objectid::regtype;
      END IF;
    ELSIF node.classid='pg_operator'::regclass AND node.objectid >= 16384 THEN
      IF EXISTS (SELECT 1 FROM pg_operator o JOIN pg_roles r ON r.oid=o.oprowner WHERE o.oid=node.objectid AND NOT r.rolsuper) THEN
        RAISE EXCEPTION 'untrusted_dependency: operator %',node.objectid::regoperator;
      END IF;
    ELSIF node.classid='pg_class'::regclass THEN
      IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner
        WHERE c.oid=node.objectid AND c.relkind='S' AND NOT r.rolsuper) THEN
        RAISE EXCEPTION 'untrusted_dependency: sequence %',node.objectid::regclass;
      END IF;
    ELSIF node.classid='pg_collation'::regclass AND node.objectid >= 16384 THEN
      IF EXISTS (SELECT 1 FROM pg_collation c JOIN pg_roles r ON r.oid=c.collowner
        WHERE c.oid=node.objectid AND NOT r.rolsuper) THEN
        RAISE EXCEPTION 'untrusted_dependency: collation %',node.objectid;
      END IF;
    END IF;
  END LOOP;
END
