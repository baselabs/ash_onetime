DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'kind',c.relkind,'persistence',c.relpersistence,'partition',c.relispartition,
    'am',c.relam,'owner',c.relowner,
    'columns',(SELECT coalesce(jsonb_agg(jsonb_build_object(
      'name',a.attname,'type',a.atttypid,'typmod',a.atttypmod,'collation',a.attcollation,
      'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
      'default',@routines@.ash_onetime_maintenance_normalize(d.adbin::text,relation_oid::oid)
    ) ORDER BY a.attname),'[]') FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
      WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
    'constraints',(SELECT coalesce(jsonb_agg(value ORDER BY value::text),'[]') FROM (
      SELECT jsonb_build_object('type',x.contype,'deferrable',x.condeferrable,'deferred',x.condeferred,
        'validated',x.convalidated,'enforced',x.conenforced,
        'keys',(SELECT jsonb_agg(a.attname ORDER BY k.ordinality) FROM unnest(x.conkey) WITH ORDINALITY k(num,ordinality)
          JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num),
        'expression',@routines@.ash_onetime_maintenance_normalize(x.conbin::text,relation_oid::oid),
        'foreign_relation',x.confrelid,'operators',x.conexclop,
        'equality',jsonb_build_array(x.conpfeqop,x.conppeqop,x.conffeqop),
        'backed',x.conindid<>0)
        -- PostgreSQL forbids inheritance from a partition; a leaf cannot have
        -- descendants, so NO INHERIT cannot affect its index-backed constraints.
        || CASE WHEN x.contype IN ('p','u','x') AND c.relkind='r' AND c.relispartition
          THEN '{}'::jsonb ELSE jsonb_build_object('noinherit',x.connoinherit) END
        AS value FROM pg_constraint x WHERE x.conrelid=c.oid
    ) constraints),
    'indexes',(SELECT coalesce(jsonb_agg(value ORDER BY value::text),'[]') FROM (
      SELECT jsonb_build_object('am',ic.relam,'kind',ic.relkind,'owner',ic.relowner,
        'unique',i.indisunique,'primary',i.indisprimary,'exclusion',i.indisexclusion,
        'immediate',i.indimmediate,'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive,
        'nulls_not_distinct',i.indnullsnotdistinct,'nkeys',i.indnkeyatts,'natts',i.indnatts,
        'keys',(SELECT jsonb_agg(coalesce(a.attname,'<expression>') ORDER BY k.ordinality)
          FROM unnest(i.indkey) WITH ORDINALITY k(num,ordinality) LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num),
        'opclasses',i.indclass::text,'collations',i.indcollation::text,'options',i.indoption::text,
        'expressions',@routines@.ash_onetime_maintenance_normalize(i.indexprs::text,relation_oid::oid),
        'predicate',@routines@.ash_onetime_maintenance_normalize(i.indpred::text,relation_oid::oid)) AS value
      FROM pg_index i JOIN pg_class ic ON ic.oid=i.indexrelid WHERE i.indrelid=c.oid
    ) indexes),
    'partition_key',(SELECT jsonb_build_object('strategy',p.partstrat,'natts',p.partnatts,
      'keys',(SELECT jsonb_agg(coalesce(a.attname,'<expression>') ORDER BY k.ordinality)
        FROM unnest(p.partattrs) WITH ORDINALITY k(num,ordinality) LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num),
      'opclasses',p.partclass::text,'collations',p.partcollation::text,
      'expressions',@routines@.ash_onetime_maintenance_normalize(p.partexprs::text,relation_oid::oid))
      FROM pg_partitioned_table p WHERE p.partrelid=c.oid),
    'triggers',(SELECT coalesce(jsonb_agg(value ORDER BY value::text),'[]') FROM (
      SELECT (to_jsonb(t)-ARRAY['oid','tgrelid','tgparentid','tgfoid','tgqual','tgattr']) || jsonb_build_object(
        'function',p.proname,'arguments',p.proargtypes::text,
        'namespace',(SELECT nspname FROM pg_namespace WHERE oid=p.pronamespace),
        'parent',t.tgparentid<>0,
        'attributes',(SELECT jsonb_agg(a.attname ORDER BY k.ordinality) FROM unnest(t.tgattr) WITH ORDINALITY k(num,ordinality)
          JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num),
        'qual',@routines@.ash_onetime_maintenance_normalize(t.tgqual::text,relation_oid::oid)) AS value
      FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid=c.oid
    ) triggers),
    'rules',(SELECT count(*) FROM pg_rewrite r WHERE r.ev_class=c.oid),
    'statistics',(SELECT count(*) FROM pg_statistic_ext s WHERE s.stxrelid=c.oid),
    'incoming_foreign_keys',(SELECT count(*) FROM pg_constraint x WHERE x.confrelid=c.oid)
  ) INTO STRICT result FROM pg_class c WHERE c.oid=relation_oid;
  RETURN result;
END
