defmodule AshOnetime.Test.StoreCase do
  @moduledoc false

  alias AshOnetime.Store.{Claim, Postgres}
  alias AshOnetime.Test.{Clock, Migration, Repo}
  alias Ecto.Adapters.SQL.Sandbox
  alias ExUnit.Callbacks

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshOnetime.Test.StoreCase

      alias AshOnetime.Store
      alias AshOnetime.Store.{Claim, Postgres, Result}
      alias AshOnetime.Test.{Clock, Migration, Repo}
      alias Ecto.Adapters.SQL
    end
  end

  setup context do
    owner = Sandbox.start_owner!(Repo, shared: false, sandbox: context[:unboxed] != true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Clock.freeze(DateTime.utc_now())
    on_exit(&Clock.reset/0)

    prefix = Map.fetch!(context, :prefix)
    {:ok, target: Postgres.for_repo(Repo, prefix)}
  end

  def install_store!(options \\ []) do
    installation = Migration.install_generated!(options)

    Callbacks.on_exit(fn ->
      Migration.uninstall_generated!(installation)
    end)

    installation
  end

  def idempotency_request(label, options \\ []) do
    Claim.idempotency(
      operation_hash: hash("operation:" <> label),
      scope_hash: hash("scope:" <> label),
      key_hash: hash("key:" <> label),
      fingerprint: hash("fingerprint:" <> label),
      retention_seconds: Keyword.get(options, :retention_seconds, 3_600)
    )
    |> elem(1)
  end

  def nonce_request(label, options \\ []) do
    now = Keyword.get(options, :issued_at, Clock.now())

    verified = %AshOnetime.Verified{
      key: "nonce:" <> label,
      issued_at: now,
      expires_at: Keyword.get(options, :expires_at),
      verifier_id: Keyword.get(options, :verifier_id, "test-verifier")
    }

    Claim.nonce(
      operation_hash: hash("operation:" <> label),
      scope_hash: hash("scope:" <> label),
      key_hash: hash("key:" <> label),
      verified: [verified],
      max_age: Keyword.get(options, :max_age, 60),
      clock_skew: Keyword.get(options, :clock_skew, 0),
      clock: Clock
    )
    |> elem(1)
  end

  def hash(value), do: :crypto.hash(:sha256, value)
end

defmodule AshOnetime.Test.StoreResource do
  @moduledoc false

  use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

  postgres do
    table "store_resources"
    repo AshOnetime.Test.Repo
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end

defmodule AshOnetime.Test.TenantStoreResource do
  @moduledoc false

  use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer

  postgres do
    table "store_resources"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]
  end
end
