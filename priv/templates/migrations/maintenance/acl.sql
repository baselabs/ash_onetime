DECLARE
  maintainer oid;
  bad boolean;
BEGIN
  SELECT (last_counts->>'maintenance_role')::oid INTO maintainer
  FROM @schema@.ash_onetime_maintenance_runs WHERE step='install';
  SELECT EXISTS (
    SELECT 1 WHERE maintainer<>@owner@ AND pg_has_role(maintainer,@owner@,'MEMBER')
    UNION ALL
    SELECT 1 FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
    WHERE c.oid IN (SELECT @schema@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner
      AND (c.oid NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass)
           OR a.privilege_type IN ('TRIGGER','TRUNCATE','REFERENCES'))
    UNION ALL
    SELECT 1 FROM pg_attribute t JOIN pg_class c ON c.oid=t.attrelid CROSS JOIN LATERAL aclexplode(t.attacl) a
    WHERE c.oid IN (SELECT @schema@.ash_onetime_maintenance_relations()) AND a.grantee<>c.relowner
      AND (c.oid NOT IN (@idempotency@::regclass,@nonce@::regclass,@payload@::regclass)
           OR a.privilege_type='REFERENCES')
    UNION ALL
    SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    WHERE p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=@schema_name@)
      AND p.proname LIKE 'ash_onetime_%' AND a.grantee<>p.proowner
      AND (a.grantee<>maintainer OR a.is_grantable)
  ) INTO bad;
  RETURN NOT bad;
END
