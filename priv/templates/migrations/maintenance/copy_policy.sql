DECLARE
  flags record;
  policy record;
  role_list text;
  target_name text;
BEGIN
  SELECT format('%I.%I', n.nspname, c.relname) INTO STRICT target_name
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=child_oid;
  -- Resolve with quoted identifiers, including schemas containing quotes or dollar delimiters.
  SELECT relrowsecurity, relforcerowsecurity INTO STRICT flags
  FROM pg_class WHERE oid=format('%I.%I', @schema_name@, 'ash_onetime_response_payloads')::regclass;
  EXECUTE format('ALTER TABLE %s %s ROW LEVEL SECURITY', target_name,
    CASE WHEN flags.relrowsecurity THEN 'ENABLE' ELSE 'DISABLE' END);
  EXECUTE format('ALTER TABLE %s %s FORCE ROW LEVEL SECURITY', target_name,
    CASE WHEN flags.relforcerowsecurity THEN '' ELSE 'NO' END);
  FOR policy IN SELECT p.* FROM pg_policy p
    WHERE p.polrelid=format('%I.%I', @schema_name@, 'ash_onetime_response_payloads')::regclass
  LOOP
    SELECT string_agg(CASE WHEN role_oid=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(role_oid)) END, ', ')
    INTO role_list FROM unnest(policy.polroles) role_oid;
    EXECUTE format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s', policy.polname, target_name,
      CASE WHEN policy.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
      CASE policy.polcmd WHEN '*' THEN 'ALL' WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END,
      role_list,
      CASE WHEN policy.polqual IS NULL THEN '' ELSE ' USING (' || pg_get_expr(policy.polqual,policy.polrelid) || ')' END,
      CASE WHEN policy.polwithcheck IS NULL THEN '' ELSE ' WITH CHECK (' || pg_get_expr(policy.polwithcheck,policy.polrelid) || ')' END);
  END LOOP;
END
