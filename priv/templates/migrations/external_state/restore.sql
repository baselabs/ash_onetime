<%= case fragment do %>
<% :ddl -> %>
CREATE TABLE @schema@.ash_onetime_external_state_restore (
  routine_identity text NOT NULL,
  definition text NOT NULL,
  owner_oid oid NOT NULL,
  configuration text[],
  security_definer boolean NOT NULL,
  grants aclitem[]
  -- rule:external-journal-primary-key
  , PRIMARY KEY (routine_identity)
) USING heap
<% :create -> %>
      EXECUTE replace(<%= "#" <> "{maintenance_literal(" <> inspect(EEx.eval_file(__ENV__.file, fragment: :ddl)) <> ")}" %>,'@schema@',format('%I',install_schema));
      -- Default privileges belong to the operator; the journal is owner-only.
      -- rule:external-journal-owner-only
      FOR grantee IN SELECT DISTINCT a.grantee FROM pg_class c,
        LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        WHERE c.oid=format('%I.ash_onetime_external_state_restore',install_schema)::regclass
          AND a.grantee<>c.relowner LOOP
        EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE %I.ash_onetime_external_state_restore FROM %s CASCADE',install_schema,
          CASE WHEN grantee=0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(grantee)) END);
      END LOOP;
<% end %>
