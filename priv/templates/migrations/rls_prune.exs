defmodule <%= inspect(module) %> do
  use Ecto.Migration

  # RLS-safe payload-partition prune support (see the row-level security
  # section in documentation/operations.md). Creates, only when missing:
  #
  #   * the NOLOGIN role ash_onetime_prune — it owns no tables and the
  #     application role is never a member of it;
  #   * the boolean emptiness function ash_onetime_partition_empty/3 —
  #     SECURITY DEFINER, owned by the prune role, fixed search_path, EXECUTE
  #     revoked from PUBLIC and granted to the application role; it returns
  #     only the boolean, never row data;
  #   * SELECT grants and a permissive FOR SELECT policy for the prune role on
  #     the claims and payload tables, and the same on every payload child
  #     partition, which are also brought in line with the parent's ENABLE/
  #     FORCE row-security settings and full policy set.
  #
  # Refuses clearly when run as the application role, when the application
  # role holds SET, USAGE, or ADMIN on the prune role, or when creating the
  # prune role needs CREATEROLE the migrating role does not hold. Creating the
  # role and the function as a superuser bootstrap is the documented
  # alternative for the last case.

  @prune_role "ash_onetime_prune"
  @prune_function "ash_onetime_partition_empty"
  @app_role "<%= app_role %>"

  def up do
    execute("""
    DO $guards$
    DECLARE
      is_superuser boolean := EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = current_user AND rolsuper
      );
      can_create boolean := is_superuser OR (
        SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user
      );
      role_exists boolean := EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ash_onetime_prune');
    BEGIN
      IF current_user = '<%= app_role %>' THEN
        RAISE EXCEPTION 'ash_onetime: the migrating role must not be the application role'
          USING ERRCODE = '42501';
      END IF;

      IF role_exists THEN
        -- pg_has_role knows MEMBER/USAGE/SET; membership (which is what
        -- ADMIN builds on) shows up as a pg_auth_members row.
        IF pg_has_role('<%= app_role %>', 'ash_onetime_prune', 'SET')
           OR pg_has_role('<%= app_role %>', 'ash_onetime_prune', 'USAGE')
           OR EXISTS (
             SELECT 1 FROM pg_auth_members m
             JOIN pg_roles pr ON pr.oid = m.roleid
             JOIN pg_roles ar ON ar.oid = m.member
             WHERE pr.rolname = 'ash_onetime_prune' AND ar.rolname = '<%= app_role %>'
           ) THEN
          RAISE EXCEPTION 'ash_onetime: the application role must hold no SET, USAGE, or ADMIN on ash_onetime_prune'
            USING ERRCODE = '42501';
        END IF;

        IF NOT is_superuser
           AND NOT EXISTS (
             SELECT 1 FROM pg_auth_members m
             JOIN pg_roles pr ON pr.oid = m.roleid
             JOIN pg_roles mr ON mr.oid = m.member
             WHERE pr.rolname = 'ash_onetime_prune'
               AND mr.rolname = current_user
               AND (m.admin_option OR m.set_option)
           )
           AND NOT pg_has_role(current_user, 'ash_onetime_prune', 'USAGE') THEN
          RAISE EXCEPTION 'ash_onetime: ash_onetime_prune already exists and this role cannot administer it; bootstrap via a superuser'
            USING ERRCODE = '42501';
        END IF;
      ELSE
        IF NOT can_create THEN
          RAISE EXCEPTION 'ash_onetime: creating ash_onetime_prune needs CREATEROLE (or a superuser bootstrap)'
            USING ERRCODE = '42501';
        END IF;
      END IF;
    END
    $guards$;
    """)

    execute("""
    DO $create$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ash_onetime_prune') THEN
        EXECUTE format('CREATE ROLE %I NOLOGIN', 'ash_onetime_prune');
      END IF;
    END
    $create$;
    """)

    # The migrating role transfers the function's ownership, which needs SET
    # on the new owner (PostgreSQL 16+); it is never granted to the
    # application role. The self-grant needs ADMIN on the prune role, which
    # its creator holds.
    execute("""
    DO $grant$
    BEGIN
      EXECUTE format('GRANT %I TO %I WITH INHERIT FALSE, SET TRUE', 'ash_onetime_prune', current_user);
    END
    $grant$;
    """)

    execute("""
    CREATE FUNCTION #{q(@prune_function)}(partition_name text, from_date date, until_date date)
    RETURNS boolean
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, #{quote_identifier(search_schema())}
    AS $prune$
    DECLARE
      function_schema text := '#{search_schema()}';
      partition_oid regclass := partition_name::regclass;
      partition_relname text;
      payload_count bigint;
      claim_count bigint;
      ddl text;
    BEGIN
      -- Only a child of this schema's payload parent is ever counted.
      IF NOT EXISTS (
        SELECT 1 FROM pg_inherits i
        JOIN pg_class parent ON parent.oid = i.inhparent
        JOIN pg_namespace ns ON ns.oid = parent.relnamespace
        WHERE i.inhrelid = partition_oid
          AND ns.nspname = function_schema
          AND parent.relname = 'ash_onetime_response_payloads'
      ) THEN
        RAISE EXCEPTION 'ash_onetime: % is not a payload partition', partition_name
          USING ERRCODE = '22023';
      END IF;

      -- The prune role's permissive USING (true) policy is only ORed with
      -- other permissive policies. A consumer's RESTRICTIVE tenant policy is
      -- ANDed in even inside this SECURITY DEFINER function, so the counts
      -- below would see only the current tenant and a partition holding
      -- another tenant's payloads could read as empty. Refuse to count
      -- instead: fail closed with the row-security error the store maps to
      -- :row_security_blocked.
      partition_relname := (SELECT relname FROM pg_class WHERE oid = partition_oid);

      IF EXISTS (
        SELECT 1 FROM pg_policies p
        WHERE p.schemaname = function_schema
          AND p.permissive = 'RESTRICTIVE'
          AND p.cmd IN ('ALL', 'SELECT')
          AND ('public' = ANY(p.roles) OR 'ash_onetime_prune' = ANY(p.roles))
          AND p.tablename IN (
            'ash_onetime_idempotency_claims', 'ash_onetime_response_payloads', partition_relname
          )
      ) THEN
        RAISE EXCEPTION 'ash_onetime: row-level security policy would filter the prune count'
          USING ERRCODE = '42501';
      END IF;

      ddl := 'SELECT count(*) FROM ' || partition_oid;
      EXECUTE ddl INTO payload_count;

      SELECT count(*) INTO claim_count
      FROM #{q("ash_onetime_idempotency_claims")}
      WHERE response_partition >= from_date AND response_partition < until_date;

      RETURN payload_count = 0 AND claim_count = 0;
    END
    $prune$;
    """)

    # The ACL is set while the migrating role still owns the function; after
    # the ownership transfer it cannot act as the prune role (INHERIT FALSE),
    # and a revoke or grant made then is silently a no-op. PUBLIC loses
    # EXECUTE; the application role gains it (the store's prune calls it as
    # the application), and so does the migrating role — it created the
    # function and keeps the right to verify and drive prunes itself once the
    # ownership transfer takes that implicit right away.
    execute("REVOKE ALL ON FUNCTION #{q(@prune_function)}(text, date, date) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{q(@prune_function)}(text, date, date) TO #{@app_role}")

    # Transferring ownership requires CREATE on the schema for the NEW owner
    # (PostgreSQL keeps the object creatable by its owner); USAGE stays with
    # the prune role afterwards, CREATE does not.
    execute("GRANT USAGE, CREATE ON SCHEMA #{quote_identifier(prefix_schema())} TO #{@prune_role}")
    execute("ALTER FUNCTION #{q(@prune_function)}(text, date, date) OWNER TO #{@prune_role}")
    execute("REVOKE CREATE ON SCHEMA #{quote_identifier(prefix_schema())} FROM #{@prune_role}")

    # A grant to the migrating role made while it still owns the function is
    # a silent no-op: the owner's rights are implicit, and they vanish with the
    # ownership transfer. After the transfer the prune role owns the function,
    # and the migrating role holds exactly SET on it — so it steps into the
    # role to grant itself EXECUTE, keeping the right to verify and drive
    # prunes. PUBLIC still holds nothing; only the app role, the migrating
    # role, and the prune role itself can call the function.
    execute("""
    DO $grant_execute$
    DECLARE
      migrator text := current_user;
    BEGIN
      EXECUTE format('SET ROLE %I', 'ash_onetime_prune');
      EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(text, date, date) TO %I',
        '#{search_schema()}', 'ash_onetime_partition_empty', migrator);
      EXECUTE 'RESET ROLE';
    END
    $grant_execute$;
    """)


    execute("GRANT SELECT ON #{q("ash_onetime_idempotency_claims")} TO #{@prune_role}")
    execute("GRANT SELECT ON #{q("ash_onetime_response_payloads")} TO #{@prune_role}")

    execute("""
    DO $policy$
    DECLARE
      table_name text;
    BEGIN
      FOREACH table_name IN ARRAY ARRAY['ash_onetime_idempotency_claims', 'ash_onetime_response_payloads']
      LOOP
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
          WHERE schemaname = '#{prefix_schema()}'
            AND tablename = table_name
            AND policyname = 'ash_onetime_prune_select'
        ) THEN
          EXECUTE format('CREATE POLICY ash_onetime_prune_select ON %I.%I FOR SELECT TO %I USING (true)',
            '#{prefix_schema()}', table_name, 'ash_onetime_prune');
        END IF;
      END LOOP;
    END
    $policy$;
    """)

    # Bring existing payload children in line with the parent: copy the
    # parent's ENABLE/FORCE row-security settings and every parent policy the
    # child is missing, and grant the prune role SELECT directly (a child
    # queried by name applies its own grants and policies).
    execute("""
    DO $children$
    DECLARE
      parent_schema text := '#{prefix_schema()}';
      parent_name text := 'ash_onetime_response_payloads';
      parent_flags record;
      child_oid regclass;
      child_relname text;
      r record;
      roles text;
      cmd_part text;
      using_part text;
      check_part text;
      ddl text;
    BEGIN
      SELECT relrowsecurity AS enabled, relforcerowsecurity AS forced
      INTO parent_flags
      FROM pg_class c
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
      WHERE ns.nspname = parent_schema AND c.relname = parent_name;

      FOR child_oid IN
        SELECT c.oid
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class parent ON parent.oid = i.inhparent
        JOIN pg_namespace ns ON ns.oid = parent.relnamespace
        WHERE ns.nspname = parent_schema AND parent.relname = parent_name
      LOOP
        child_relname := (SELECT relname FROM pg_class WHERE oid = child_oid);

        IF parent_flags.enabled THEN
          ddl := 'ALTER TABLE ' || child_oid || ' ENABLE ROW LEVEL SECURITY';
          EXECUTE ddl;
        END IF;

        IF parent_flags.forced THEN
          ddl := 'ALTER TABLE ' || child_oid || ' FORCE ROW LEVEL SECURITY';
          EXECUTE ddl;
        END IF;

        ddl := 'GRANT SELECT ON ' || child_oid || ' TO ash_onetime_prune';
        EXECUTE ddl;

        FOR r IN
          SELECT * FROM pg_policies
          WHERE schemaname = parent_schema AND tablename = parent_name
        LOOP
          IF NOT EXISTS (
            SELECT 1 FROM pg_policies p
            WHERE p.schemaname = parent_schema
              AND p.tablename = child_relname
              AND p.policyname = r.policyname
          ) THEN
            roles := coalesce(
              (SELECT string_agg(quote_ident(member), ', ') FROM unnest(r.roles) AS member),
              'PUBLIC'
            );
            cmd_part := CASE r.cmd WHEN 'ALL' THEN '' ELSE 'FOR ' || r.cmd || ' ' END;
            using_part := CASE WHEN r.qual IS NULL THEN '' ELSE 'USING (' || r.qual || ') ' END;
            check_part := CASE WHEN r.with_check IS NULL THEN '' ELSE 'WITH CHECK (' || r.with_check || ')' END;
            ddl := 'CREATE POLICY ' || quote_ident(r.policyname) || ' ON ' || child_oid ||
              ' AS ' || r.permissive || ' ' || cmd_part || 'TO ' || roles || ' ' || using_part || check_part;
            EXECUTE ddl;
          END IF;
        END LOOP;
      END LOOP;
    END
    $children$;
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS #{q(@prune_function)}(text, date, date)")

    execute("""
    DO $teardown$
    DECLARE
      table_name text;
      child_oid regclass;
      ddl text;
    BEGIN
      FOREACH table_name IN ARRAY ARRAY['ash_onetime_idempotency_claims', 'ash_onetime_response_payloads']
      LOOP
        IF EXISTS (
          SELECT 1 FROM pg_policies
          WHERE schemaname = '#{prefix_schema()}'
            AND tablename = table_name
            AND policyname = 'ash_onetime_prune_select'
        ) THEN
          ddl := 'DROP POLICY ash_onetime_prune_select ON ' || quote_ident('#{prefix_schema()}') || '.' || quote_ident(table_name);
          EXECUTE ddl;
        END IF;

        ddl := 'REVOKE SELECT ON ' || quote_ident('#{prefix_schema()}') || '.' || quote_ident(table_name) || ' FROM ash_onetime_prune';
        EXECUTE ddl;
      END LOOP;

      FOR child_oid IN
        SELECT c.oid
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class parent ON parent.oid = i.inhparent
        JOIN pg_namespace ns ON ns.oid = parent.relnamespace
        WHERE ns.nspname = '#{prefix_schema()}' AND parent.relname = 'ash_onetime_response_payloads'
      LOOP
        IF EXISTS (
          SELECT 1 FROM pg_policies p
          WHERE p.schemaname = '#{prefix_schema()}'
            AND p.tablename = (SELECT relname FROM pg_class WHERE oid = child_oid)
            AND p.policyname = 'ash_onetime_prune_select'
        ) THEN
          ddl := 'DROP POLICY ash_onetime_prune_select ON ' || child_oid;
          EXECUTE ddl;
        END IF;

        ddl := 'REVOKE SELECT ON ' || child_oid || ' FROM ash_onetime_prune';
        EXECUTE ddl;
      END LOOP;
    END
    $teardown$;
    """)

    # The prune role itself is left in place: it is shared by name across
    # installs and dropping it would break other schemas using it.
    execute("""
    DO $ungrant$
    BEGIN
      EXECUTE format('REVOKE %I FROM %I', 'ash_onetime_prune', current_user);
    END
    $ungrant$;
    """)
  end


  defp prefix_schema do
    prefix() || "public"
  end

  defp search_schema do
    prefix_schema()
  end

  defp q(name) do
    case prefix() do
      nil -> quote_identifier(name)
      prefix -> quote_identifier(prefix) <> "." <> quote_identifier(name)
    end
  end

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
end
