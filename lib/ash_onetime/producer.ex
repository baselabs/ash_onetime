defmodule AshOnetime.Producer do
  @moduledoc """
  Produces the `executing_only` values of a locally executed protected action.

  A protection that declares `executing_only` names on an action without an
  `external_effect` must declare `produce: MyProducer`. The package calls `produce/2`
  once per fresh execution, inside the action's transaction, after admission has
  claimed the key and before the action body runs. It is never called on a replay or a
  recovery.

  `produce/2` returns `{:ok, values}`, where `values` is a map with exactly the declared
  names as keys, each a binary of at most 64 KiB. The package seals the map at once to
  a key that exists only inside the `AshOnetime.deliver/2` call, and the caller of that
  call is the only party that can open it. Any other return, a raise, a throw or an
  exit fails the action with `:executing_only_invalid` and rolls it back; no exception,
  stacktrace or returned term reaches Ash.

  The trusted context carries `:actor` and `:tenant` (when present) and the executing
  `:resource` and `:action`.

  The producer itself is outside the package's guarantees: it creates the value, so it
  must not log, persist, emit or return it anywhere else.
  """

  @type subject :: Ash.Changeset.t() | Ash.ActionInput.t()
  @type trusted_context :: %{
          optional(:actor) => term(),
          optional(:tenant) => term(),
          required(:resource) => module(),
          required(:action) => atom()
        }

  @callback produce(subject(), trusted_context()) :: {:ok, %{optional(atom()) => binary()}}
end
