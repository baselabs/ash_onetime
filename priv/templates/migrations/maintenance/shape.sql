DECLARE
  result jsonb;
BEGIN
  WITH related_constraints AS MATERIALIZED (
    SELECT k.* FROM pg_constraint k WHERE k.oid IN (SELECT tgconstraint FROM pg_trigger WHERE tgrelid=relation_oid)
  ), needed_relations AS MATERIALIZED (
    SELECT relation_oid AS oid UNION SELECT confrelid FROM pg_constraint WHERE conrelid=relation_oid
    UNION SELECT tgconstrrelid FROM pg_trigger WHERE tgrelid=relation_oid
    UNION SELECT conrelid FROM related_constraints UNION SELECT confrelid FROM related_constraints
    UNION SELECT indrelid FROM pg_index WHERE indexrelid IN (SELECT tgconstrindid FROM pg_trigger WHERE tgrelid=relation_oid)
  ), relation_roles AS MATERIALIZED (
    SELECT c.oid,jsonb_build_object('schema',n.nspname,
      'root',regexp_replace(coalesce(parent.relname,c.relname),'^(ash_onetime_|aor_[0-9]+_)','ash_onetime_'),
      'bound',regexp_replace(c.relpartbound::text,':location [-0-9]+',':location -1','g')) AS role
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    LEFT JOIN pg_inherits inheritance ON inheritance.inhrelid=c.oid
    LEFT JOIN pg_class parent ON parent.oid=inheritance.inhparent
    WHERE c.oid IN (SELECT oid FROM needed_relations) AND c.relkind IN ('r','p')
  ), constraint_roles AS MATERIALIZED (
    SELECT k.oid,jsonb_build_object('type',k.contype,'relation',own.role,
      'keys',(SELECT jsonb_agg(a.attname ORDER BY u.ordinality) FROM unnest(k.conkey) WITH ORDINALITY u(num,ordinality) JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=u.num),
      'foreign_relation',foreign_role.role,
      'foreign_keys',(SELECT jsonb_agg(a.attname ORDER BY u.ordinality) FROM unnest(k.confkey) WITH ORDINALITY u(num,ordinality) JOIN pg_attribute a ON a.attrelid=k.confrelid AND a.attnum=u.num),
      'update',k.confupdtype,'delete',k.confdeltype,'match',k.confmatchtype) AS role
    FROM related_constraints k LEFT JOIN relation_roles own ON own.oid=k.conrelid
    LEFT JOIN relation_roles foreign_role ON foreign_role.oid=k.confrelid
  ), index_roles AS MATERIALIZED (
    SELECT i.indexrelid,jsonb_build_object('relation',r.role,'primary',i.indisprimary,'unique',i.indisunique,
      'keys',(SELECT jsonb_agg(a.attname ORDER BY u.ordinality) FROM unnest(i.indkey) WITH ORDINALITY u(num,ordinality) JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=u.num)) AS role
    FROM pg_index i JOIN relation_roles r ON r.oid=i.indrelid WHERE i.indexrelid IN (SELECT tgconstrindid FROM pg_trigger WHERE tgrelid=relation_oid)
  )
  SELECT jsonb_build_object(
    'kind',c.relkind,'persistence',c.relpersistence,'partition',c.relispartition,
    'am',c.relam,'owner',c.relowner,
    'columns',(SELECT coalesce(jsonb_agg(jsonb_build_object(
      -- rule:maintenance-shape-type
      -- rule:maintenance-shape-typmod
      -- rule:maintenance-shape-collation
      'name',a.attname,'type',a.atttypid,'typmod',a.atttypmod,'collation',a.attcollation,
      -- end-rule:maintenance-shape-type
      'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
      -- rule:maintenance-shape-default
      'default',@routines@.ash_onetime_maintenance_normalize(d.adbin::text,relation_oid::oid)
    ) ORDER BY a.attname),'[]') FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
      WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
    'constraints',(SELECT coalesce(jsonb_agg(value ORDER BY value::text),'[]') FROM (
      SELECT jsonb_build_object('type',x.contype,'deferrable',x.condeferrable,'deferred',x.condeferred,
        'validated',x.convalidated,'enforced',x.conenforced,
        'keys',(SELECT jsonb_agg(a.attname ORDER BY k.ordinality) FROM unnest(x.conkey) WITH ORDINALITY k(num,ordinality)
          JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num),
        -- rule:maintenance-shape-constraint-expression
        'expression',@routines@.ash_onetime_maintenance_normalize(x.conbin::text,relation_oid::oid),
        'foreign_relation',(SELECT role FROM relation_roles WHERE oid=x.confrelid),'operators',x.conexclop,
        'foreign_keys',(SELECT jsonb_agg(a.attname ORDER BY k.ordinality) FROM unnest(x.confkey) WITH ORDINALITY k(num,ordinality) JOIN pg_attribute a ON a.attrelid=x.confrelid AND a.attnum=k.num),
        'foreign_update',x.confupdtype,'foreign_delete',x.confdeltype,'foreign_match',x.confmatchtype,
        'equality',jsonb_build_array(x.conpfeqop,x.conppeqop,x.conffeqop),
        'backed',x.conindid<>0)
        -- PostgreSQL forbids inheritance from a partition; a leaf cannot have
        -- descendants, so NO INHERIT cannot affect its index-backed constraints.
        -- rule:maintenance-restore-fixpoint
        || CASE WHEN x.contype IN ('p','u','x') AND c.relkind='r' AND c.relispartition
          THEN '{}'::jsonb ELSE jsonb_build_object('noinherit',x.connoinherit) END
        AS value FROM pg_constraint x WHERE x.conrelid=c.oid
    ) constraints),
    'indexes',(SELECT coalesce(jsonb_agg(value ORDER BY value::text),'[]') FROM (
      -- rule:maintenance-shape-index-am
      SELECT jsonb_build_object('am',ic.relam,'kind',ic.relkind,'owner',ic.relowner,
        'unique',i.indisunique,'primary',i.indisprimary,'exclusion',i.indisexclusion,
        'immediate',i.indimmediate,'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive,
        'nulls_not_distinct',i.indnullsnotdistinct,'nkeys',i.indnkeyatts,'natts',i.indnatts,
        'keys',(SELECT jsonb_agg(coalesce(a.attname,'<expression>') ORDER BY k.ordinality)
          FROM unnest(i.indkey) WITH ORDINALITY k(num,ordinality) LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=k.num),
        -- rule:maintenance-shape-opclass
        'opclasses',i.indclass::text,'collations',i.indcollation::text,'options',i.indoption::text,
        -- rule:maintenance-shape-index-expressions
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
      SELECT (to_jsonb(t)-ARRAY['oid','tgrelid','tgparentid','tgfoid','tgqual','tgattr','tgname','tgconstrrelid','tgconstrindid','tgconstraint']) || jsonb_build_object(
        -- rule:shape-ri-normalization
        'name',CASE WHEN t.tgisinternal AND p.proname LIKE 'RI_FKey_%' AND p.pronamespace='pg_catalog'::regnamespace THEN p.proname ELSE t.tgname END,
        'constraint_relation',(SELECT role FROM relation_roles WHERE oid=t.tgconstrrelid),
        'constraint_index',(SELECT role FROM index_roles WHERE indexrelid=t.tgconstrindid),
        'constraint',(SELECT role FROM constraint_roles WHERE oid=t.tgconstraint),
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
