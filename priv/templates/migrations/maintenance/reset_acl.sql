DECLARE
  grant_row record;
  column_row record;
  target_name text;
BEGIN
  SELECT format('%I.%I', n.nspname, c.relname) INTO STRICT target_name
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = relation_oid;
  FOR grant_row IN
    SELECT DISTINCT a.grantee FROM pg_class c,
      LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
    WHERE c.oid = relation_oid AND a.grantee <> c.relowner
  LOOP
    EXECUTE format('REVOKE %s ON TABLE %s FROM %s CASCADE',
      CASE WHEN owner_only THEN 'ALL PRIVILEGES' ELSE 'TRIGGER, TRUNCATE, REFERENCES, MAINTAIN' END,
      target_name, CASE WHEN grant_row.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grant_row.grantee)) END);
  END LOOP;
  FOR column_row IN
    SELECT a.attname, x.grantee FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid,
      LATERAL aclexplode(a.attacl) x
    WHERE a.attrelid = relation_oid AND a.attnum > 0 AND NOT a.attisdropped AND x.grantee <> c.relowner
  LOOP
    EXECUTE format('REVOKE %s (%I) ON TABLE %s FROM %s CASCADE',
      CASE WHEN owner_only THEN 'ALL PRIVILEGES' ELSE 'REFERENCES' END,
      column_row.attname, target_name,
      CASE WHEN column_row.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(column_row.grantee)) END);
  END LOOP;
END
