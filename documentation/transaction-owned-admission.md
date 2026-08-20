# Transaction-owned admission

`AshOnetime.Transaction` is the public boundary for a host that already owns one authoritative
Ecto transaction. It applies the same PostgreSQL-authoritative idempotency and nonce semantics
without wrapping the host effect in an Ash action.

The boundary never starts or commits a transaction. The caller must already be inside a
PostgreSQL `READ COMMITTED` transaction. Admission, the host mutation, its audit record, and the
exact replay bytes therefore commit or roll back together.

## Idempotency

```elixir
alias AshOnetime.Transaction

MyApp.Repo.transaction(fn ->
  options = [
    operation: {MyApp.Management, :execute},
    partition: tenant_id,
    scope: principal_id,
    key: idempotency_key,
    fingerprint: :crypto.hash(:sha256, canonical_request_bytes),
    retention_seconds: 86_400,
    codec: "myapp.management-response.v1"
  ]

  case Transaction.idempotency(MyApp.Repo, options) do
    {:execute, admission} ->
      exact_response_bytes = MyApp.Management.execute_and_encode!()
      :ok = Transaction.complete(admission, exact_response_bytes)
      {:fresh, exact_response_bytes}

    {:replay, exact_response_bytes} ->
      {:replay, exact_response_bytes}

    {:error, error} ->
      MyApp.Repo.rollback(error)
  end
end)
```

The same partition/scope/key with a different fingerprint returns
`:key_reused_with_different_request`. A matching incomplete claim returns
`:request_in_progress`. Replay validates the stored codec and SHA-256 payload digest before
returning bytes.

## One-time nonce

```elixir
verified = [
  %AshOnetime.Verified{
    key: nonce,
    issued_at: signed_created_at,
    expires_at: signed_expires_at,
    verifier_id: "management-gateway"
  }
]

:ok =
  AshOnetime.Transaction.nonce(MyApp.Repo,
    operation: {MyApp.Management, :signed_request_nonce},
    partition: tenant_id,
    scope: credential_id,
    key: nonce,
    verified: verified,
    max_age: 300,
    clock_skew: 0
  )
```

Every verified fact must carry the exact nonce key. A collision returns
`:nonce_already_used`. The nonce spend rolls back when the caller transaction rolls back.

## Authority identity

- `operation` is a local `{module, action}` atom pair. It is domain-separated and hashed; it is
  not caller input.
- `partition` isolates tenant or authority-plane ownership in one store installation.
- `scope` identifies the principal or credential authority within that partition.
- `key` is the idempotency key or nonce within that scope.
- `fingerprint` is an exact 32-byte digest supplied by the host's canonical request boundary.

`partition`, `scope`, and `key` are nonempty bounded UTF-8 binaries with no NUL bytes. Options
are closed: unknown or duplicate keys fail with `:invalid_request`. The optional `prefix`
selects an existing PostgreSQL schema; it does not replace logical partitioning.

## Installation and upgrade

Fresh install migrations include logical partitions. Existing v1.0 installations run:

```sh
mix ash_onetime.gen.logical_partitions --repo MyApp.Repo
mix ecto.migrate
```

The upgrade backfills existing rows to `global`. Its down migration refuses while non-global
claims or payloads exist, preventing a rollback from merging distinct authorities. See
[Upgrading](upgrading.md) and [Operations](operations.md).
