DECLARE
  expected jsonb := '{}'::jsonb; -- @relation_manifest@
BEGIN
  IF expected->>'server_version_num'=current_setting('server_version_num') THEN RETURN expected; END IF;
  -- A major/minor server update can change node serialization. Reference DDL
  -- is rebuilt on this server in this transaction, then entirely removed.
  RETURN @routines@.ash_onetime_maintenance_reference(false::boolean);
END
