defmodule AshOnetime do
  @moduledoc """
  Explicit keyed-effect semantics for Ash actions.

  `ash_onetime` separates replay-safe idempotency from collision-rejecting one-time
  nonces. Protected actions must declare a strategy and an explicit scope.
  """
end
