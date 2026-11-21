defmodule AshOnetime.Test.DeliveryFacts.Observer do
  @moduledoc false

  # The Ash facts of §2.7.7, observed from inside a real `deliver/2` call. Every probe
  # notes an event to the process that set itself as observer, with the pid that ran the
  # probe and the state of the one armed entry in that pid's dictionary at that moment.
  # A probe that runs in a process with no observer notes nothing.

  @observer {__MODULE__, :observer}

  def watch, do: Process.put(@observer, self())
  def unwatch, do: Process.delete(@observer)

  def note(event) do
    case Process.get(@observer) do
      pid when is_pid(pid) -> send(pid, {:fact, event, self(), entry_state()})
      _none -> :ok
    end

    :ok
  end

  @doc "The state of the armed entry in this process: `:none` outside a call."
  def entry_state do
    Enum.find_value(Process.get(), :none, fn
      {{AshOnetime.Delivery, _hash}, entry} when is_tuple(entry) -> elem(entry, 0)
      _other -> nil
    end)
  end

  @doc "Every noted event, in order, as `{event, pid, entry_state}`."
  def events(acc \\ []) do
    receive do
      {:fact, event, pid, state} -> events([{event, pid, state} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

defmodule AshOnetime.Test.DeliveryFacts.Tracer do
  @moduledoc false
  use Ash.Tracer

  # Records every callback Ash makes, with its arguments, to the recording process.
  @recorder {__MODULE__, :recorder}

  def record, do: Process.put(@recorder, self())
  def stop, do: Process.delete(@recorder)

  def records(acc \\ []) do
    receive do
      {:trace, callback, args} -> records([{callback, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @impl true
  def start_span(type, name), do: put(:start_span, [type, name])

  @impl true
  def stop_span, do: put(:stop_span, [])

  @impl true
  def get_span_context do
    put(:get_span_context, [])
    nil
  end

  @impl true
  def set_span_context(context), do: put(:set_span_context, [context])

  @impl true
  def set_metadata(type, metadata), do: put(:set_metadata, [type, metadata])

  @impl true
  def set_error(error, opts), do: put(:set_error, [error, opts])

  @impl true
  def set_handled_error(error, opts), do: put(:set_handled_error, [error, opts])

  defp put(callback, args) do
    case Process.get(@recorder) do
      pid when is_pid(pid) -> send(pid, {:trace, callback, args})
      _none -> :ok
    end

    :ok
  end
end

defmodule AshOnetime.Test.DeliveryFacts.Notifier do
  @moduledoc false
  use Ash.Notifier

  alias AshOnetime.Test.DeliveryFacts.Observer

  @impl true
  def notify(_notification), do: Observer.note(:notification)
end

defmodule AshOnetime.Test.DeliveryFacts.Check do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  alias AshOnetime.Test.DeliveryFacts.Observer

  @impl true
  def describe(_opts), do: "notes the authorization step"

  @impl true
  def match?(_actor, _context, _opts) do
    Observer.note(:authorize)
    true
  end
end

defmodule AshOnetime.Test.DeliveryFacts.Noted do
  @moduledoc false
  use Ash.Resource.Calculation

  alias AshOnetime.Test.DeliveryFacts.Observer

  # A calculation the return-type load runs, noting when it ran.
  @impl true
  def calculate(records, _opts, _context) do
    Observer.note(:load)
    Enum.map(records, fn _record -> "noted" end)
  end
end

defmodule AshOnetime.Test.DeliveryFacts.Run do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias AshOnetime.Test.DeliveryFacts.{Issuer, Observer, Receipt}

  # :issue persists a receipt in the action's transaction and returns it with one
  # notification for the observer notifier; :nothing returns no value; :numbers returns
  # a list.
  @impl true
  def run(input, _opts, _context) do
    Observer.note(:run)
    result(input.action.name, input)
  end

  defp result(name, input) when name in [:issue, :plain_issue] do
    with {:ok, receipt} <-
           Receipt
           |> Ash.Changeset.for_create(
             :create,
             %{token: Ash.ActionInput.get_argument(input, :token)},
             tenant: input.tenant
           )
           |> Ash.create() do
      notification = %Ash.Notifier.Notification{
        resource: Issuer,
        domain: AshOnetime.Test.DeliveryFacts.Domain,
        action: input.action,
        data: receipt,
        for: [AshOnetime.Test.DeliveryFacts.Notifier]
      }

      {:ok, receipt, [notification]}
    end
  end

  defp result(name, _input) when name in [:nothing, :plain_nothing], do: :ok
  defp result(name, _input) when name in [:numbers, :plain_numbers], do: {:ok, [1, 2, 3]}
end

defmodule AshOnetime.Test.DeliveryFacts.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOnetime.Test.DeliveryFacts.Receipt
    resource AshOnetime.Test.DeliveryFacts.Issuer
  end
end

defmodule AshOnetime.Test.DeliveryFacts.Receipt do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.DeliveryFacts.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ash_onetime_facts_receipts"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :token, :string, public?: true, allow_nil?: false
  end

  calculations do
    calculate :noted, :string, AshOnetime.Test.DeliveryFacts.Noted, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:token]
    end
  end
end

defmodule AshOnetime.Test.DeliveryFacts.Issuer do
  @moduledoc false

  use Ash.Resource,
    domain: AshOnetime.Test.DeliveryFacts.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOnetime.Resource]

  # The generic actions never read or write this table; the data layer gives them the
  # repository's transaction. The `plain_` actions carry no protection: they pin Ash's
  # own return shapes.
  postgres do
    table "ash_onetime_facts_issuers"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  # The host carries a public `:token` of its own, so a verifier that checked a generic
  # action's response fields against the host instead of the returned resource would
  # still compile this file; the compile matrix (`returned_fields`,
  # `returned_action_field`) is what tells the two apart.
  attributes do
    uuid_primary_key :id
    attribute :token, :string, public?: true
  end

  # Ash 3.37.2 validates ActionInput loads against the action resource; later
  # releases validate the return resource. The probe is legal on both, while
  # its observed calculation still runs on the returned Receipt after the action.
  calculations do
    calculate :noted, :string, AshOnetime.Test.DeliveryFacts.Noted, public?: true
  end

  actions do
    action :issue, :struct do
      constraints instance_of: AshOnetime.Test.DeliveryFacts.Receipt
      transaction? true
      argument :token, :string, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      run {AshOnetime.Test.DeliveryFacts.Run, []}
    end

    action :nothing do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "facts"
      run {AshOnetime.Test.DeliveryFacts.Run, []}
    end

    action :numbers, {:array, :integer} do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "facts"
      run {AshOnetime.Test.DeliveryFacts.Run, []}
    end

    action :plain_issue, :struct do
      constraints instance_of: AshOnetime.Test.DeliveryFacts.Receipt
      transaction? true
      argument :token, :string, allow_nil?: false
      run {AshOnetime.Test.DeliveryFacts.Run, []}
    end

    action :plain_nothing do
      transaction? true
      run {AshOnetime.Test.DeliveryFacts.Run, []}
    end

    action :plain_numbers, {:array, :integer} do
      transaction? true
      run {AshOnetime.Test.DeliveryFacts.Run, []}
    end
  end

  policies do
    policy always() do
      authorize_if AshOnetime.Test.DeliveryFacts.Check
    end
  end

  onetime do
    protect :issue do
      strategy :idempotency
      scope([{:static, "facts"}])
      key({:client, :request_key})
      fingerprint(arguments: [:token], attributes: [])

      response(AshOnetime.Codec.Resource,
        fields: [:id, :token],
        classify: AshOnetime.Test.StoreClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :nothing do
      strategy :idempotency
      scope([{:static, "facts"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :numbers do
      strategy :idempotency
      scope([{:static, "facts"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end
  end
end
