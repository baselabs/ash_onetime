DECLARE
  maintainer oid;
  bad boolean;
  visibility_oid oid := to_regprocedure(format('%I.ash_onetime_claim_visible(bytea,text,uuid)',@routine_schema_name@));
BEGIN
  SELECT (last_counts->>'maintenance_role')::oid INTO maintainer
  FROM @schema@.ash_onetime_maintenance_runs WHERE step='install';
  SELECT EXISTS (
    SELECT 1 WHERE maintainer<>@owner@ AND pg_has_role(maintainer,@owner@,'MEMBER')
    UNION ALL
    SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
    -- rule:acl-outcome-exemption
    -- rule:acl-child-table-owner-only
    WHERE c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner
      AND (c.oid NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass,@outcomes@::regclass) AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass)
           OR (c.oid<>@outcomes@::regclass AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass) AND a.privilege_type IN ('TRIGGER','TRUNCATE','REFERENCES','MAINTAIN')))
    UNION ALL
    SELECT 1 FROM pg_attribute t JOIN pg_class c ON c.oid=t.attrelid CROSS JOIN LATERAL aclexplode(t.attacl) a
    -- rule:acl-child-column-owner-only
    WHERE c.oid IN (SELECT @routines@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner
      AND (c.oid NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass,@outcomes@::regclass) AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass)
           OR (c.oid<>@outcomes@::regclass AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid AND inhparent=@outcomes@::regclass) AND a.privilege_type='REFERENCES'))
    UNION ALL
    SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    -- rule:maintenance-routine-acl
    WHERE p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=@routine_schema_name@)
      AND EXISTS (SELECT 1 FROM @schema@.ash_onetime_maintenance_runs r,
        LATERAL jsonb_array_elements(r.last_counts->'routines') m WHERE r.step='install'
          AND m->>'name'=p.proname AND m->>'arguments'=p.proargtypes::text)
      AND p.oid<>visibility_oid AND a.grantee<>p.proowner
      AND (a.grantee<>maintainer OR a.is_grantable)
    UNION ALL
    -- rule:visibility-helper-acl-audit
    SELECT 1 WHERE visibility_oid IS NULL OR EXISTS (
      SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      WHERE p.oid=visibility_oid AND (a.grantee NOT IN (0,p.proowner) OR a.is_grantable OR a.privilege_type<>'EXECUTE'))
      OR (SELECT count(*) FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=visibility_oid AND a.grantee IN (0,p.proowner) AND a.privilege_type='EXECUTE' AND NOT a.is_grantable)<>2
  ) INTO bad;
  RETURN NOT bad;
END
