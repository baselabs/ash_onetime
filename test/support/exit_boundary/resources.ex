defmodule AshOnetime.Test.ExitBoundary.Faults do
  @moduledoc false

  # The run's planted canaries and fault modes, in the root's dictionary: set in the
  # root's setup, before arming, so planting them is never observed.
  @canaries {__MODULE__, :canaries}
  @fault {__MODULE__, :fault}
  @peer {__MODULE__, :peer}

  def plant(short, long) when is_binary(short) and is_binary(long) and byte_size(short) == 8 and byte_size(long) <= 65_536,
    do: Process.put(@canaries, %{short: short, long: long})

  def canaries, do: Process.get(@canaries) || %{short: random(8), long: random(32)}
  def put(fault), do: Process.put(@fault, fault)
  def fault, do: Process.get(@fault)

  # The external peer's connection, opened by the test outside the run: an effect that
  # opened its own pool would leave the pool's processes and timers behind the run.
  def put_peer(connection) when is_pid(connection), do: Process.put(@peer, connection)
  def peer, do: Process.get(@peer) || raise("no peer connection was planted")

  # A recovery's first call stops here, in an unobserved worker, until the test kills it:
  # `{:pause, point, observer, reference}` with `point` `:before_execute` (the peer has
  # nothing, so recovery proves absence) or `:after_execute` (the peer holds the effect).
  def pause(point) do
    case fault() do
      {:pause, ^point, observer, reference} ->
        send(observer, {:boundary_pause, reference, self()})
        receive(do: (:never -> :ok))

      _other ->
        :ok
    end
  end

  defp random(size), do: :crypto.strong_rand_bytes(size)
end

defmodule AshOnetime.Test.ExitBoundary.Producer do
  @moduledoc false
  @behaviour AshOnetime.Producer

  alias AshOnetime.Test.ExitBoundary.Faults

  # The local producer: both canaries, or the fault the run planted. A raise and an error
  # carry the long canary, so a package that let either through is found by the search.
  @impl true
  def produce(_subject, _context) do
    canaries = Faults.canaries()

    case Faults.fault() do
      :producer_raise ->
        raise ArgumentError, canaries.long

      :producer_error ->
        {:error, canaries.long}

      :producer_contract ->
        {:ok, %{short: canaries.short, long: canaries.long, extra: canaries.long}}

      _none ->
        {:ok, canaries}
    end
  end
end

defmodule AshOnetime.Test.ExitBoundary.External do
  @moduledoc false
  @behaviour AshOnetime.ExternalEffect

  alias AshOnetime.Test.ExitBoundary.Faults
  alias AshOnetime.Test.ExternalPeer

  # The external effect of the withheld resource: the peer records the effect once and
  # `execute/3` returns both canaries with the peer's result. `:execute_unknown` runs the
  # effect at the peer and reports the outcome unknown; recovery then finds it.
  @impl true
  def execute(operation_key, subject, _context) do
    Faults.pause(:before_execute)

    if Faults.fault() == {:interrupt, :before_execute} do
      {:error, :outcome_unknown}
    else
    result =
      ExternalPeer.execute(subject.to_tenant, operation_key, %{effect: "boundary"},
        connection: Faults.peer()
      )

    Faults.pause(:after_execute)

    if Faults.fault() == :finalize_replay, do: AshOnetime.Test.ExitBoundary.FinalizeReplay.complete(subject, operation_key)

    case Faults.fault() do
      :execute_unknown -> {:error, :outcome_unknown}
      {:interrupt, :after_execute} -> {:error, :outcome_unknown}
      _none -> {:ok, result, Faults.canaries()}
    end
    end
  end

  @impl true
  def recover(operation_key, subject, _context) do
    case Faults.fault() do
      {:interrupt, _} -> :unknown
      _ -> ExternalPeer.recover(subject.to_tenant, operation_key, :authoritative,
        connection: Faults.peer())
    end
  end
end

defmodule AshOnetime.Test.ExitBoundary.ReturnedExternal do
  @moduledoc false
  @behaviour AshOnetime.ExternalEffect

  alias AshOnetime.Test.ExitBoundary.Faults
  alias AshOnetime.Test.ExternalPeer

  # The twin's external effect: the same peer call with no executing-only values.
  @impl true
  def execute(operation_key, subject, _context) do
    Faults.pause(:before_execute)

    if Faults.fault() == {:interrupt, :before_execute} do
      {:error, :outcome_unknown}
    else
    result =
      ExternalPeer.execute(subject.to_tenant, operation_key, %{effect: "boundary"},
        connection: Faults.peer()
      )

    Faults.pause(:after_execute)

    if Faults.fault() == :finalize_replay, do: AshOnetime.Test.ExitBoundary.FinalizeReplay.complete(subject, operation_key)

    case Faults.fault() do
      :execute_unknown -> {:error, :outcome_unknown}
      {:interrupt, :after_execute} -> {:error, :outcome_unknown}
      _none -> {:ok, result}
    end
    end
  end

  @impl true
  def recover(operation_key, subject, _context) do
    case Faults.fault() do
      {:interrupt, _} -> :unknown
      _ -> ExternalPeer.recover(subject.to_tenant, operation_key, :authoritative,
        connection: Faults.peer())
    end
  end
end

defmodule AshOnetime.Test.ExitBoundary.Codec do
  @moduledoc false
  @behaviour AshOnetime.Codec

  alias AshOnetime.Error
  alias AshOnetime.Test.ExitBoundary.Faults

  # A package callback (E24). `:codec_encode` and `:codec_decode` fail it.
  @impl true
  def format_tag, do: "boundary"

  @impl true
  def encode(value, _contract, _opts) do
    if Faults.fault() == :codec_encode,
      do: {:error, Error.new(:response_value_invalid, "boundary codec refused the value")},
      else: {:ok, format_tag(), :erlang.term_to_binary(value)}
  end

  @impl true
  def decode("boundary", payload, _contract, _opts) do
    if Faults.fault() == :codec_decode,
      do: {:error, Error.new(:response_value_invalid, "boundary codec refused the payload")},
      else: {:ok, :erlang.binary_to_term(payload, [:safe])}
  end
end

defmodule AshOnetime.Test.ExitBoundary.ResponseClassifier do
  @moduledoc false
  @behaviour AshOnetime.ResponseClassifier

  alias AshOnetime.Test.ExitBoundary.Faults

  # A package callback (E24): stores, or rejects or rolls back when the run says so.
  @impl true
  def classify(value, _context) do
    case Faults.fault() do
      :classify_reject -> {:reject, :rejected}
      :classify_rollback -> {:rollback, :rolled_back}
      _none -> {:store, value}
    end
  end
end

defmodule AshOnetime.Test.ExitBoundary.Hold do
  @moduledoc false
  @behaviour AshOnetime.Hold

  alias AshOnetime.Test.ExitBoundary.Faults

  # A package callback (E24): no hold, or an invalid outcome when the run says so.
  @impl true
  def reference(_result, _context) do
    case Faults.fault() do
      :hold_invalid -> :invalid
      :held -> {:hold, "boundary-hold"}
      _ -> :none
    end
  end
end

defmodule AshOnetime.Test.ExitBoundary.Consumer do
  @moduledoc false

  alias AshOnetime.Test.ExitBoundary.{Faults, Recorder}

  # A consumer after-action hook on every action of both sides: a change on the CRUD
  # actions, a preparation on the generic ones. It hands what a consumer hook sees (the
  # subject's full context and the result) to `Recorder`, a recorded callback, so X2 compares what a consumer receives on
  # each side. Pure: it runs on replay too and has no effect. With a fault planted it
  # raises, exits or throws after recording.
  def after_action(subject, result) do
    Recorder.after_action(subject, result)

    case Faults.fault() do
      :after_raise -> raise ArgumentError, "the consumer hook failed"
      :after_exit -> exit(:consumer_hook_failed)
      :after_throw -> throw(:consumer_hook_failed)
      _none -> {:ok, result}
    end
  end

  def replay_capabilities,
    do: %{notifications: false, effects: false, around_action: false, marker: :unused}
end

defmodule AshOnetime.Test.ExitBoundary.Recorder do
  @moduledoc false

  # Recorded as a package callback (E24): its arguments are what X2 compares.
  def after_action(_subject, _result), do: :ok
end

defmodule AshOnetime.Test.ExitBoundary.ConsumerChange do
  @moduledoc false
  use Ash.Resource.Change

  alias AshOnetime.Test.ExitBoundary.Consumer

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, &Consumer.after_action/2)

  def replay_safety(_opts), do: :pure
  def replay_capabilities(_opts), do: Consumer.replay_capabilities()
end

defmodule AshOnetime.Test.ExitBoundary.ConsumerPreparation do
  @moduledoc false
  use Ash.Resource.Preparation

  alias AshOnetime.Test.ExitBoundary.Consumer

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def prepare(input, _opts, _context),
    do: Ash.ActionInput.after_action(input, &Consumer.after_action/2)

  def replay_safety(_opts), do: :pure
  def replay_capabilities(_opts), do: Consumer.replay_capabilities()
end

defmodule AshOnetime.Test.ExitBoundary.GenericRun do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context), do: {:ok, Ash.ActionInput.get_argument(input, :value)}
end

defmodule AshOnetime.Test.ExitBoundary.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshOnetime.Test.ExitBoundary.Withheld)
    resource(AshOnetime.Test.ExitBoundary.Returned)
  end
end

defmodule AshOnetime.Test.ExitBoundary.Withheld do
  @moduledoc false

  # The executing-only side of every boundary run: each action declares two values, a
  # short and a long one, from the local producer or the external effect.

  use Ash.Resource,
    domain: AshOnetime.Test.ExitBoundary.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table("ash_onetime_boundary_records")
    repo(AshOnetime.Test.Repo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:amount, :integer, public?: true, allow_nil?: false)
    attribute(:retired, :boolean, public?: true, allow_nil?: false, default: false)
  end

  actions do
    defaults([:read])

    create :seed do
      accept([:amount])
    end

    create :issue do
      transaction?(true)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    update :rotate do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :revoke do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :retire do
      transaction?(true)
      soft?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(set_attribute(:retired, true))
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    action :mint, :integer do
      transaction?(true)
      argument(:value, :integer, allow_nil?: false)
      argument(:request_key, :string, allow_nil?: false)
      run({AshOnetime.Test.ExitBoundary.GenericRun, []})
      prepare(AshOnetime.Test.ExitBoundary.ConsumerPreparation)
    end

    create :external_issue do
      transaction?(true)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    update :external_rotate do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :external_revoke do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :external_retire do
      transaction?(true)
      soft?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(set_attribute(:retired, true))
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    action :external_mint, :integer do
      transaction?(true)
      argument(:value, :integer, allow_nil?: false)
      argument(:request_key, :string, allow_nil?: false)
      run({AshOnetime.Test.ExitBoundary.GenericRun, []})
      prepare(AshOnetime.Test.ExitBoundary.ConsumerPreparation)
    end
  end

  onetime do
    protect :issue do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      produce(AshOnetime.Test.ExitBoundary.Producer)
    end

    protect :rotate do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      produce(AshOnetime.Test.ExitBoundary.Producer)
    end

    protect :revoke do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      produce(AshOnetime.Test.ExitBoundary.Producer)
    end

    protect :retire do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      produce(AshOnetime.Test.ExitBoundary.Producer)
    end

    protect :mint do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      produce(AshOnetime.Test.ExitBoundary.Producer)
    end

    protect :external_issue do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      external_effect(AshOnetime.Test.ExitBoundary.External)
    end

    protect :external_rotate do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      external_effect(AshOnetime.Test.ExitBoundary.External)
    end

    protect :external_revoke do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      external_effect(AshOnetime.Test.ExitBoundary.External)
    end

    protect :external_retire do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      external_effect(AshOnetime.Test.ExitBoundary.External)
    end

    protect :external_mint do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      executing_only([:short, :long])
      external_effect(AshOnetime.Test.ExitBoundary.External)
    end
  end
end

defmodule AshOnetime.Test.ExitBoundary.Returned do
  @moduledoc false

  # The twin: the same actions, table width, store options and callbacks as the withheld
  # resource, with no executing-only values. Every boundary run is compared with it.

  use Ash.Resource,
    domain: AshOnetime.Test.ExitBoundary.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOnetime.Resource]

  postgres do
    table("ash_onetime_boundary_records")
    repo(AshOnetime.Test.Repo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:amount, :integer, public?: true, allow_nil?: false)
    attribute(:retired, :boolean, public?: true, allow_nil?: false, default: false)
  end

  actions do
    defaults([:read])

    create :seed do
      accept([:amount])
    end

    create :issue do
      transaction?(true)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    update :rotate do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :revoke do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :retire do
      transaction?(true)
      soft?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(set_attribute(:retired, true))
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    action :mint, :integer do
      transaction?(true)
      argument(:value, :integer, allow_nil?: false)
      argument(:request_key, :string, allow_nil?: false)
      run({AshOnetime.Test.ExitBoundary.GenericRun, []})
      prepare(AshOnetime.Test.ExitBoundary.ConsumerPreparation)
    end

    create :external_issue do
      transaction?(true)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    update :external_rotate do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      accept([:amount])
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :external_revoke do
      transaction?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    destroy :external_retire do
      transaction?(true)
      soft?(true)
      require_atomic?(false)
      argument(:request_key, :string, allow_nil?: false)
      argument(:note, :string, default: "boundary")
      change(set_attribute(:retired, true))
      change(AshOnetime.Test.ExitBoundary.ConsumerChange)
    end

    action :external_mint, :integer do
      transaction?(true)
      argument(:value, :integer, allow_nil?: false)
      argument(:request_key, :string, allow_nil?: false)
      run({AshOnetime.Test.ExitBoundary.GenericRun, []})
      prepare(AshOnetime.Test.ExitBoundary.ConsumerPreparation)
    end
  end

  onetime do
    protect :issue do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
    end

    protect :rotate do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
    end

    protect :revoke do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
    end

    protect :retire do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
    end

    protect :mint do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
    end

    protect :external_issue do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      external_effect(AshOnetime.Test.ExitBoundary.ReturnedExternal)
    end

    protect :external_rotate do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      external_effect(AshOnetime.Test.ExitBoundary.ReturnedExternal)
    end

    protect :external_revoke do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      external_effect(AshOnetime.Test.ExitBoundary.ReturnedExternal)
    end

    protect :external_retire do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      external_effect(AshOnetime.Test.ExitBoundary.ReturnedExternal)
    end

    protect :external_mint do
      strategy(:idempotency)
      scope([{:static, "boundary"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value], attributes: [])

      response(AshOnetime.Test.ExitBoundary.Codec,
        fields: [],
        classify: AshOnetime.Test.ExitBoundary.ResponseClassifier
      )

      retention(3_600)
      hold(AshOnetime.Test.ExitBoundary.Hold)
      external_effect(AshOnetime.Test.ExitBoundary.ReturnedExternal)
    end
  end
end
