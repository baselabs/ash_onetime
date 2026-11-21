DECLARE
  offending text;
BEGIN
  SELECT string_agg(format('%s.%I', p.polrelid::regclass, p.polname), ', ' ORDER BY p.polrelid, p.polname)
  INTO offending FROM pg_policy p
  WHERE p.polrelid IN (SELECT @routines@.ash_onetime_maintenance_relations())
  AND NOT (p.polname='ash_onetime_claim_visibility' AND (p.polrelid=@outcomes@::regclass OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=p.polrelid AND inhparent=@outcomes@::regclass)))
  AND (p.polname='ash_onetime_maintenance' OR EXISTS (SELECT 1 FROM unnest(p.polroles) r(role_oid)
              WHERE role_oid = 0 OR pg_has_role(@owner@, role_oid, 'MEMBER')))
  AND (p.polname <> 'ash_onetime_maintenance' OR NOT p.polpermissive OR p.polcmd <> '*'
       OR p.polroles <> ARRAY[@owner@::oid]
       OR @routines@.ash_onetime_maintenance_normalize(p.polqual::text,p.polrelid::oid) IS DISTINCT FROM '@policy_expression@'
       OR @routines@.ash_onetime_maintenance_normalize(p.polwithcheck::text,p.polrelid::oid) IS DISTINCT FROM '@policy_expression@');

  SELECT concat_ws(', ', nullif(offending,''), string_agg(format('%s: invalid claim visibility', r::regclass), ', ')) INTO offending
  FROM @routines@.ash_onetime_maintenance_relations() r
  WHERE (r=@outcomes@::regclass OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid=r AND inhparent=@outcomes@::regclass))
    -- rule:policy-claim-visibility
    AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=r AND p.polname='ash_onetime_claim_visibility'
      AND p.polpermissive AND p.polcmd='*' AND p.polroles=ARRAY[0::oid]
      AND @routines@.ash_onetime_maintenance_normalize(p.polqual::text,p.polrelid::oid)='@visibility_expression@'
      AND @routines@.ash_onetime_maintenance_normalize(p.polwithcheck::text,p.polrelid::oid)='@visibility_expression@');
  SELECT concat_ws(', ', nullif(offending,''), string_agg(format('%s: missing ash_onetime_maintenance', r::regclass), ', '))
  INTO offending FROM @routines@.ash_onetime_maintenance_relations() r
  WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = r AND p.polname = 'ash_onetime_maintenance');
  -- rule:maintenance-policy
  IF offending <> '' THEN RETURN offending; END IF;
  RETURN NULL;
END
