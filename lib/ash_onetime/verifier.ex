defmodule AshOnetime.Verifier do
  @moduledoc """
  Behavior contract for trusted local verification callbacks.

  The `context` map passed to `verify/2` is the BOUNDED callback context: `%{resource:,
  action:}` — exactly the trusted local facts the admission path derives itself. Caller-
  supplied context (actor, tenant, etc.) is NOT forwarded (AGENTS.md: "verification
  callbacks return trusted local facts; action input cannot supply pre-verified facts"). If
  a future callback needs actor-binding, that is a deliberate, separately-approved decision,
  not a latent affordance shipped by the bounded context.

  Verifiers and minters run in supervised, unlinked workers outside the caller's
  transaction. The default deadline is 5,000 ms (`:callback_timeout_ms` application
  configuration); a protection's `:verifier_timeout_ms` limit can override it, up
  to 30,000 ms. Deadline overruns are killed and report `:verification_timeout`.
  Raises, throws, exits, kills and malformed facts report
  `:verifier_contract_violation` for either callback kind.

  An explicit `{:error, reason}` reports `:verification_failed`, except typed
  `AshOnetime.Error` codes on the allowlist: `:invalid_signature`, `:key_unusable`,
  `:custody_unavailable`, `:custody_timeout`, `:outside_window`,
  `:algorithm_mismatch` and `:namespace_mismatch`. These retain their code with a
  fixed package message and empty details. A verifier wrapping `Token.verify/3`
  can return its error directly without collapsing a holder outage into refusal.
  """

  @callback verify(raw_token :: binary(), context :: map()) ::
              {:ok, AshOnetime.Verified.t()} | {:error, term()}
  @callback algorithm() :: :hmac_sha256 | :ed25519
  @callback trust_model() :: :same_service | :separated
end
