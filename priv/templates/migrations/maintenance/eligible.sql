BEGIN
  RETURN transaction_timestamp() > retain_until;
END
