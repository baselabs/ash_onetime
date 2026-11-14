DECLARE
  offending text;
BEGIN
  SELECT string_agg(format('%s.%I', p.polrelid::regclass, p.polname), ', ' ORDER BY p.polrelid, p.polname)
  INTO offending FROM pg_policy p
  WHERE p.polrelid IN (SELECT @schema@.ash_onetime_maintenance_relations())
  AND (p.polname='ash_onetime_maintenance' OR EXISTS (SELECT 1 FROM unnest(p.polroles) r(role_oid)
              WHERE role_oid = 0 OR pg_has_role(@owner@, role_oid, 'MEMBER')))
  AND (p.polname <> 'ash_onetime_maintenance' OR NOT p.polpermissive OR p.polcmd <> '*'
       OR p.polroles <> ARRAY[@owner@::oid]
       OR regexp_replace(p.polqual::text,':location [-0-9]+',':location -1','g') IS DISTINCT FROM '@policy_expression@'
       OR regexp_replace(p.polwithcheck::text,':location [-0-9]+',':location -1','g') IS DISTINCT FROM '@policy_expression@');

  SELECT concat_ws(', ', offending, string_agg(format('%s: missing ash_onetime_maintenance', r::regclass), ', '))
  INTO offending FROM @schema@.ash_onetime_maintenance_relations() r
  WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = r AND p.polname = 'ash_onetime_maintenance');
  IF offending <> '' THEN RETURN offending; END IF;
  RETURN NULL;
END
