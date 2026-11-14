BEGIN
  RETURN coalesce(current_setting('ash_onetime.maintenance', true) = 'on',false)
    AND current_user = (SELECT r.rolname FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner WHERE c.oid=@payload@::regclass);
END
