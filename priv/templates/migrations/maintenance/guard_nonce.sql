BEGIN
  IF pg_catalog.current_setting('session_replication_role') = 'replica'
    -- rule:M-replica-admit-nonce
    AND pg_catalog.pg_has_role(current_user, (SELECT relowner FROM pg_catalog.pg_class WHERE oid=TG_RELID), 'SET') THEN
    RETURN OLD;
  END IF;
  -- rule:nonce-guard-inline-eligibility
  IF NOT (transaction_timestamp() > OLD.retain_until) THEN
    RAISE EXCEPTION 'nonce claim is inside its retention horizon' USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END
