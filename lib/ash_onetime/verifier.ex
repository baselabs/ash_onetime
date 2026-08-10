defmodule AshOnetime.Verifier do
  @moduledoc """
  Behaviour for trusted local verification callbacks.

  The `context` map passed to `verify/2` is the BOUNDED callback context: `%{resource:,
  action:}` — exactly the trusted local facts the admission path derives itself. Caller-
  supplied context (actor, tenant, etc.) is NOT forwarded (AGENTS.md: "verification
  callbacks return trusted local facts; action input cannot supply pre-verified facts"). If
  a future callback needs actor-binding, that is a deliberate, separately-approved decision,
  not a latent affordance shipped by the bounded context.
  """

  @callback verify(raw_token :: binary(), context :: map()) ::
              {:ok, AshOnetime.Verified.t()} | {:error, term()}
  @callback algorithm() :: :hmac_sha256 | :ed25519
  @callback trust_model() :: :same_service | :separated
end
