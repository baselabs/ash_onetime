BEGIN
  -- rule:cleanup-boundary
  RETURN transaction_timestamp() > retain_until;
END
