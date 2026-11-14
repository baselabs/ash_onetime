DECLARE
  result text := regexp_replace(tree, ':location [-0-9]+', ':location -1', 'g');
  column_row record;
  object_row record;
BEGIN
  IF result IS NULL THEN RETURN NULL; END IF;
  -- Replace attribute references by names, not positions: ADD COLUMN upgrades
  -- and dump/restore may have different physical attribute numbers.
  FOR column_row IN SELECT attnum,attname FROM pg_attribute
    WHERE attrelid=relation_oid AND attnum>0 AND NOT attisdropped ORDER BY attnum DESC
  LOOP
    result := regexp_replace(result, ':(varattno|varattnosyn) ' || column_row.attnum || '( |})',
      ':\1 ' || quote_ident(column_row.attname) || '\2', 'g');
  END LOOP;
  -- Only package object identities are relocatable. Never run a type output
  -- function or an expression deparser while deciding whether a tree is safe.
  FOR object_row IN
    SELECT p.oid, 'routine:' || p.proname || '(' || p.proargtypes::text || ')' AS identity
    FROM pg_proc p WHERE p.pronamespace=(SELECT oid FROM pg_namespace WHERE nspname=@routine_schema_name@)
      AND p.proname LIKE 'ash_onetime_%'
    UNION ALL
    SELECT c.oid,'relation:' || c.relname FROM pg_class c WHERE c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=@schema_name@)
      AND c.relname LIKE 'ash_onetime_%'
  LOOP
    result := regexp_replace(result, '(:[a-z]+) ' || object_row.oid || '( |})', '\1 ' || object_row.identity || '\2','g');
  END LOOP;
  RETURN result;
END
