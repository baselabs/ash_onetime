defmodule AshOnetime.Test.DeliveryGuarded.Consumer do
  @moduledoc false

  # Consumer code ahead of the package's entry (§2.7.4). Each callback hands this module
  # what it receives: the subject when it has one, the context, and an `Ash.Scope`
  # source. The test's plan names the callback, the shape of the nested operation and
  # the process crossing; the nested operation runs once, from the first planned
  # callback whose received context carries a delivery reference, and its result is
  # kept for the test. Only results and flags are kept, never a value.

  alias Ash.Error.Invalid
  alias AshOnetime.Test.DeliveryCase
  alias AshOnetime.Test.DeliveryGuarded.Resource

  @plan {__MODULE__, :plan}
  @result {__MODULE__, :result}

  def plan!(plan), do: Process.put(@plan, Map.merge(plan, %{started?: false, saw_ref?: false}))

  def finish do
    plan = Process.delete(@plan)
    {plan, Process.delete(@result)}
  end

  def run(callback, subject, context, scope) do
    case Process.get(@plan) do
      %{callback: ^callback, started?: false} = plan ->
        if referenced?(context) do
          Process.put(@plan, %{plan | started?: true, saw_ref?: true})
          Process.put(@result, nested(plan, subject, context, scope))
        end

      _other ->
        :ok
    end

    :ok
  end

  defp referenced?(%{private: %{ash_onetime_delivery: %{ref: ref}}}) when is_binary(ref),
    do: true

  defp referenced?(_context), do: false

  defp nested(plan, subject, context, scope) do
    operation = operation(plan.shape, plan, subject, context, scope)

    case plan[:crossing] do
      :task -> operation |> Task.async() |> Task.await(60_000)
      _none -> operation.()
    end
  end

  # Shape a: the callback's own validated subject, run again.
  defp operation(:a, _plan, subject, _context, _scope) when is_struct(subject),
    do: fn -> run_subject(subject) end

  # Shape b: a rebuild carrying the received context, private included.
  defp operation(:b, plan, _subject, context, _scope),
    do: fn -> plan |> rebuild(context: context, tenant: plan.tenant) |> run_subject() end

  # Shapes cS and cC: a rebuild through Ash's scope idioms, which carry shared context
  # only. A calculation's context takes its tenant from the private context alone
  # (query/calculation.ex:126), which `Ash.Query.load/2` does not fill
  # (query/query.ex:2344), so consumer code names the tenant it already knows when the
  # scope has none, as it must for the call to be valid at all.
  defp operation(:cS, plan, _subject, _context, scope),
    do: fn -> plan |> rebuild(scoped(Ash.Scope.to_opts(scope), plan)) |> run_subject() end

  defp operation(:cC, plan, _subject, _context, scope) do
    # Ash.Context.to_opts/2 is documented as deprecated in favor of Ash.Scope.to_opts/2
    # (context.ex:28, a doc note with no compiler warning); consumer code still calls it,
    # so the probe matrix runs it too.
    fn -> plan |> rebuild(scoped(Ash.Context.to_opts(scope), plan)) |> run_subject() end
  end

  # Row N-d: nested code that is itself a deliver/2 caller.
  defp operation(:deliver_reuse, _plan, subject, _context, _scope) when is_struct(subject),
    do: fn -> AshOnetime.deliver(subject, authorize?: false) end

  defp operation(:deliver_rebuild, plan, _subject, context, _scope) do
    fn ->
      plan
      |> rebuild(context: context, tenant: plan.tenant)
      |> AshOnetime.deliver(authorize?: false)
    end
  end

  defp operation(:deliver_changed, plan, _subject, context, _scope) do
    fn ->
      plan
      |> rebuild([context: context, tenant: plan.tenant], %{note: "nested"})
      |> AshOnetime.deliver(authorize?: false)
    end
  end

  defp operation(:deliver_fail, plan, _subject, context, _scope) do
    fn ->
      plan
      |> rebuild(context: context, tenant: plan.tenant)
      |> DeliveryCase.hook(
        after_hook(plan.route),
        fn _subject, _result -> {:error, Invalid.exception(errors: [])} end,
        []
      )
      |> AshOnetime.deliver(authorize?: false)
    end
  end

  defp operation({:bulk, strategy, concurrency, input}, plan, _subject, context, _scope),
    do: fn -> bulk(plan, context, strategy, concurrency, input) end

  defp after_hook(_route), do: :after_action

  defp scoped(opts, plan), do: Keyword.put_new(opts, :tenant, plan.tenant)

  defp rebuild(plan, opts, overrides \\ %{}) do
    opts = Keyword.put(opts, :authorize?, false)
    params = Map.merge(plan.params, overrides)

    case plan.route do
      :create -> Ash.Changeset.for_create(Resource, :issue, params, opts)
      :update -> Ash.Changeset.for_update(plan.record, :rotate, params, opts)
      :destroy -> Ash.Changeset.for_destroy(plan.record, :revoke, params, opts)
      :soft_destroy -> Ash.Changeset.for_destroy(plan.record, :retire, params, opts)
      :generic -> Ash.ActionInput.for_action(Resource, :mint, params, opts)
    end
  end

  defp run_subject(%Ash.Changeset{action: %{type: :create}} = changeset),
    do: Ash.create(changeset, authorize?: false)

  defp run_subject(%Ash.Changeset{action: %{type: :update}} = changeset),
    do: Ash.update(changeset, authorize?: false)

  defp run_subject(%Ash.Changeset{action: %{type: :destroy}} = changeset),
    do: Ash.destroy(changeset, authorize?: false)

  defp run_subject(%Ash.ActionInput{} = input), do: Ash.run_action(input, authorize?: false)

  # Bulk calls carrying the received context: Ash builds each changeset itself, so each
  # has a fresh cell, and at max_concurrency 2 the hooks run in a worker.
  defp bulk(plan, context, strategy, concurrency, input) do
    opts = [
      context: context,
      tenant: plan.tenant,
      authorize?: false,
      return_records?: true,
      return_errors?: true,
      stop_on_error?: false,
      max_concurrency: concurrency,
      batch_size: 1,
      transaction: :batch
    ]

    case plan.route do
      :create ->
        Ash.bulk_create([plan.params], Resource, :issue, opts)

      route ->
        records =
          case input do
            :query -> Ash.Query.do_filter(Resource, id: plan.record.id)
            :records -> [plan.record]
          end

        action = %{update: :rotate, destroy: :revoke, soft_destroy: :retire}[route]
        opts = Keyword.merge(opts, resource: Resource, strategy: [strategy])
        params = Map.delete(plan.params, :amount)

        if route == :update,
          do: Ash.bulk_update(records, action, plan.params, opts),
          else: Ash.bulk_destroy(records, action, params, opts)
    end
  end
end

defmodule AshOnetime.Test.DeliveryGuarded.Check do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  alias AshOnetime.Test.DeliveryGuarded.Consumer

  # A consumer policy check: the shape `Ash.Policy.Check.Matches` uses. It also runs the
  # read a real consumer check may run while deciding, with the context it received, so
  # the `prepare_query/3` and calculation rows run on every route. Ash calls a
  # calculation's `load/3` only while loading it (query/query.ex:2385); the filter
  # check's `expr(allowed)` inlines the calculation's expression and never calls it.
  @impl true
  def describe(_opts), do: "runs consumer code ahead of the package's entry"

  @impl true
  def match?(_actor, authorizer, _opts) do
    subject = authorizer.subject
    Consumer.run(:policy, subject, subject.context, authorizer)

    subject.resource
    |> Ash.Query.new()
    |> Ash.Query.set_context(subject.context)
    |> Ash.Query.set_tenant(subject.tenant)
    |> Ash.Query.load(:allowed)
    |> Ash.read!(authorize?: false)

    true
  end
end

defmodule AshOnetime.Test.DeliveryGuarded.Calculation do
  @moduledoc false
  use Ash.Resource.Calculation

  alias AshOnetime.Test.DeliveryGuarded.Consumer

  @impl true
  def load(_query, _opts, context) do
    Consumer.run(:calculation, nil, context.source_context, context)
    [:amount]
  end

  @impl true
  def expression(_opts, _context), do: expr(not is_nil(amount))
end

defmodule AshOnetime.Test.DeliveryGuarded.Hooks do
  @moduledoc false

  alias AshOnetime.Admission
  alias AshOnetime.Test.DeliveryGuarded.Consumer

  # A consumer `before_transaction` hook on every protected action, as a change on the
  # CRUD actions and a preparation on the generic one. Its consumer code is an effect (it
  # may run a nested operation), so both declare themselves replay-aware and honor the
  # replay marker, as a consumer hook with effects must.

  @doc "The hook body: skipped on replay, otherwise captured and handed to the consumer."
  def run(subject) do
    unless Admission.replay?(subject) do
      send_captured(subject)
      scope = %{context: subject.context, tenant: subject.tenant}
      Consumer.run(:before_transaction, subject, subject.context, scope)
    end

    subject
  end

  def replay_capabilities,
    do: %{notifications: false, effects: true, around_action: false, marker: :consumed}

  @doc "Sends `pid` each subject the hook receives, as Ash built it, until `release/0`."
  def capture(pid) when is_pid(pid), do: Process.put({__MODULE__, :capture}, pid)
  def release, do: Process.delete({__MODULE__, :capture})

  defp send_captured(subject) do
    if pid = Process.get({__MODULE__, :capture}), do: send(pid, {:captured, subject})
  end
end

defmodule AshOnetime.Test.DeliveryGuarded.HookChange do
  @moduledoc false
  use Ash.Resource.Change

  alias AshOnetime.Test.DeliveryGuarded.Hooks

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.before_transaction(changeset, &Hooks.run/1)

  def replay_safety(_opts), do: :replay_aware
  def replay_capabilities(_opts), do: Hooks.replay_capabilities()
end

defmodule AshOnetime.Test.DeliveryGuarded.HookPreparation do
  @moduledoc false
  use Ash.Resource.Preparation

  alias AshOnetime.Test.DeliveryGuarded.Hooks

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def prepare(input, _opts, _context),
    do: Ash.ActionInput.before_transaction(input, &Hooks.run/1)

  def replay_safety(_opts), do: :replay_aware
  def replay_capabilities(_opts), do: Hooks.replay_capabilities()
end

defmodule AshOnetime.Test.DeliveryGuarded.Resource do
  @moduledoc false

  # The delivery example's actions behind consumer code at each callback ahead of the
  # package's entry: a policy check, a filter check whose authorization query reaches
  # `repo.prepare_query/3` and a calculation's `load/3`, and a `before_transaction` hook.

  use Ash.Resource,
    domain: AshOnetime.Test.DeliveryExamples.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOnetime.Resource]

  alias AshOnetime.Test.DeliveryGuarded.{Check, HookChange, HookPreparation}

  postgres do
    table "ash_onetime_delivery_guarded"
    repo AshOnetime.Test.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :amount, :integer, public?: true, allow_nil?: false
    attribute :retired, :boolean, public?: true, allow_nil?: false, default: false
  end

  actions do
    defaults [:read]

    create :seed do
      accept [:amount]
    end

    create :issue do
      transaction? true
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "outer"
      accept [:amount]
      change HookChange
    end

    update :rotate do
      transaction? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "outer"
      accept [:amount]
      change HookChange
    end

    destroy :revoke do
      transaction? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "outer"
      change HookChange
    end

    destroy :retire do
      transaction? true
      soft? true
      require_atomic? false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "outer"
      change set_attribute(:retired, true)
      change HookChange
    end

    action :mint, :integer do
      transaction? true
      argument :value, :integer, allow_nil?: false
      argument :request_key, :string, allow_nil?: false
      argument :note, :string, default: "outer"
      prepare HookPreparation
      run {AshOnetime.Test.DeliveryExamples.GenericRun, []}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:issue, :rotate, :revoke, :retire, :mint]) do
      authorize_if Check
    end

    # A filter check forces a real authorization query ahead of the entry.
    policy action([:rotate, :revoke, :retire]) do
      authorize_if expr(allowed)
    end
  end

  calculations do
    calculate :allowed, :boolean, AshOnetime.Test.DeliveryGuarded.Calculation
  end

  onetime do
    protect :issue do
      strategy :idempotency
      scope([{:static, "delivery-guarded"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :rotate do
      strategy :idempotency
      scope([{:static, "delivery-guarded"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :revoke do
      strategy :idempotency
      scope([{:static, "delivery-guarded"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :retire do
      strategy :idempotency
      scope([{:static, "delivery-guarded"}])
      key({:client, :request_key})
      fingerprint(arguments: [:note], attributes: [])

      response(AshOnetime.Test.Support.ResponseCodec,
        fields: [:id, :amount],
        classify: AshOnetime.Test.Support.ResponseClassifier
      )

      retention(3_600)
      executing_only([:secret])
      produce(AshOnetime.Test.DeliveryExamples.Producer)
    end

    protect :mint do
      strategy :idempotency
      scope([{:static, "delivery-guarded"}])
      key({:client, :request_key})
      fingerprint(arguments: [:value, :note], attributes: [])

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
