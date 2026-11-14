BEGIN
  IF NOT @routines@.ash_onetime_cleanup_eligible(OLD.retain_until::timestamptz) THEN
    RAISE EXCEPTION 'nonce claim is inside its retention horizon' USING ERRCODE = '23514';
  END IF;
  RETURN OLD;
END
