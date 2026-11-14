# Tokens and key custody

`AshOnetime.Token` signs bounded canonical envelopes. The expected algorithm, namespace and
acceptance window come from trusted configuration outside the token. The wire prefix,
canonical body and raw signature primitives remain compatible with existing tokens.

## Local material

Implement a purpose-specific source. Records carry their authoritative algorithm, key kind
and trust. Fetch secrets from your secret store; never accept them as action input.

```elixir
defmodule MyApp.TokenMaterial do
  @behaviour AshOnetime.KeyCustody.Local.Material

  def fetch(purpose, key_id, _context) do
    MyApp.SecretStore.fetch_token_material(purpose, key_id)
    # {:ok, %{algorithm: :hmac_sha256, key: secret, kind: :secret, trust: :same_service}}
    # Ed25519 :sign:   %{algorithm: :ed25519, key: seed, kind: :private, trust: :separated}
    # Ed25519 :verify: %{algorithm: :ed25519, key: public_key, kind: :public, trust: :separated}
    # Missing bindings return {:error, :not_found}.
  end
end

context = %{material: MyApp.TokenMaterial}
{:ok, token} = AshOnetime.Token.mint(nonce,
  algorithm: :ed25519, key_id: "active", namespace: "redemption")
{:ok, wire} = AshOnetime.Token.sign(token, AshOnetime.KeyCustody.Local, context)
{:ok, verified_token} = AshOnetime.Token.verify(wire, AshOnetime.KeyCustody.Local,
  algorithm: :ed25519, namespace: "redemption", max_age: 300,
  custody_context: context)
```

Signing and verification are separate lookups. Local compares the record's algorithm with
the request; a successful lookup alone proves nothing. Ed25519 verification refuses private
material. HMAC requires explicit same-service trust and a secret record. Retain old
verification records through the acceptance windows of tokens they signed. A verify-only
context needs no signing records or signing permission.

## External holders

Implement `AshOnetime.KeyCustody` when keys stay in a holder process, HSM or remote service:

```elixir
# MyApp.HolderCustody implements algorithms/0, sign/4 and verify/5.
context = %{holder: MyApp.TokenHolder, permission: :verify}
AshOnetime.Token.verify(wire, MyApp.HolderCustody,
  algorithm: :hmac_sha256, namespace: "redemption", max_age: 300,
  custody_context: context)
```

Custody signs exactly the supplied bytes using raw HMAC-SHA256 or pure RFC 8032 Ed25519.
HMAC verification stays at the holder with constant-time comparison; the verification
client need not be allowed to sign. Each key identifier binds one algorithm and purpose;
a mismatch returns `{:error, :key_unusable}`. Custody must be independent of the caller's
process dictionary and transaction because it runs in a supervised, unlinked worker.

The default deadline is 5,000 ms; configure `config :ash_onetime, :callback_timeout_ms, n`
with a positive integer up to 30,000 ms. On deadline the worker is brutally killed and its
reply/monitor messages are flushed. Verification accepts only exact `:ok`. Wire signatures
must be exactly 32 bytes for HMAC or 64 for Ed25519 before custody is called; returned
signatures must have the same exact lengths.

Custody errors use a closed vocabulary: `:invalid_signature` (verify only), `:key_unusable`,
`:unavailable`, `:timeout`. The latter two become `:custody_unavailable` and
`:custody_timeout`; a raise, exit, kill or other result becomes `:custody_contract_violation`.
All have fixed package messages and empty details. See [Errors](errors.md).

Provision `AshOnetime.KeyCustody.Conformance.materials/0` in an isolated test holder, then
run `AshOnetime.KeyCustody.Conformance.run(MyApp.HolderCustody, test_context)`. Its public
test keys must never be deployed. The suite runs every declared algorithm and checks RFC
known answers, cross-verification with the reference signers, purpose and algorithm binding,
tampering and signature lengths. Custody remains trusted cryptographic code: the suite
cannot prove a remote comparison is constant-time or prevent a dishonest `:ok`.
