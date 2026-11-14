defmodule AshOnetime.KeyCustody do
  @moduledoc """
  Trusted cryptographic custody for canonical token bytes.

  Implementations sign with raw HMAC-SHA256 or pure Ed25519 per RFC 8032 (never
  Ed25519ctx or Ed25519ph), over exactly the bytes supplied. Each key identifier
  is authoritatively bound to one algorithm and purpose; a mismatch returns
  `{:error, :key_unusable}` and must never coerce a key or algorithm.

  HMAC verification happens at the holder using constant-time comparison. A
  verify-only client needs no signing permission. HMAC remains a same-service
  trust model: possession of its verification secret confers signing power.
  Ed25519 permits public verification without private signing material.

  Custody runs in a supervised worker outside the caller's process and database
  transaction. It must not depend on the caller's process dictionary, connection
  or transaction. Context is trusted host configuration, never pre-verified action input.

  Custody is trusted cryptographic code. The package contains failures and checks
  output shape and exact signature lengths, but cannot detect a dishonest `:ok`.
  `AshOnetime.KeyCustody.Conformance` checks the primitives and rejection cases.
  Constant-time comparison at an external holder is the implementer's obligation;
  the conformance suite cannot prove it.
  """

  @type algorithm :: :hmac_sha256 | :ed25519
  @type failure :: :key_unusable | :unavailable | :timeout

  @callback algorithms() :: [algorithm()]
  @callback sign(algorithm(), binary(), binary(), term()) ::
              {:ok, binary()} | {:error, failure()}
  @callback verify(algorithm(), binary(), binary(), binary(), term()) ::
              :ok | {:error, :invalid_signature | failure()}
end
