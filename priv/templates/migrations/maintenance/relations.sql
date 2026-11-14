BEGIN
  RETURN QUERY
  WITH RECURSIVE relations(oid) AS (
    SELECT c.oid FROM pg_class c WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = @schema_name@)
    AND c.relname IN ('ash_onetime_idempotency_claims', 'ash_onetime_nonce_claims',
                     'ash_onetime_response_payloads', 'ash_onetime_maintenance_runs')
    UNION
    SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON r.oid = i.inhparent
  ) SELECT r.oid FROM relations r;
END
