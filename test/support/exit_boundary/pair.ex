defmodule AshOnetime.Test.ExitBoundary.Pair do
  @moduledoc false

  # §2.7.8 rule 4, one path observed twice: the executing-only run (`deliver/2` on the
  # withheld resource, in the run installation) and its twin (the same Ash call on the
  # returned resource, in the twin installation). Both roots use the test's unboxed
  # repository; the test's own connection seeds and snapshots each installation.
  #
  # `observe/2` returns both observations with their persisted deltas;
  # `assert_boundary!/1` checks X1 (the persisted projection), X2 (the emitted events), X3
  # (the caller's result), X4 (the residue and the terminal drain), the unclaimed events
  # and both searches (the canaries and the envelopes, in the events and in every row).
  # `assert_contained!/3` is the check of a path that has no twin (a refusal before
  # arming, a producer failure, a direct Ash call): nothing persisted, the same searches,
  # and, for a refusal before arming, nothing emitted at all outside the host's frames.
  #
  # Every failure names tables, descriptors and counts, never a term.

  alias AshOnetime.Test.ExitBoundary
  alias AshOnetime.Test.ExitBoundary.{Analysis, Faults, Normalization, Persisted}
  alias AshOnetime.Test.ExitBoundary.{Codec, External, Hold, Producer, Recorder}
  alias AshOnetime.Test.ExitBoundary.{ResponseClassifier, Returned, ReturnedExternal, Withheld}
  alias AshOnetime.Test.Repo

  @callbacks [Codec, ResponseClassifier, Hold, Recorder]
  defmodule Path do
    @moduledoc false
    # `action` is the action of both resources; `external?` whether it runs an external
    # effect; `fault` the mode planted in both roots; `input` the action's input;
    # `opts` the call's options; `record` whether the action targets a seeded record;
    # `call` how the run side calls it: `:deliver`, or `:direct` (the Ash call itself);
    # `transaction` a caller transaction around the call, `:commit` or `:rollback`, in
    # which the twin opens the same transaction and does nothing.
    defstruct [
      :action,
      :type,
      :fault,
      :key,
      :transaction,
      call: :deliver,
      external?: false,
      input: %{},
      opts: [],
      record: false
    ]
  end

  defmodule Observation do
    @moduledoc false
    defstruct [:run, :delta, :prefix, :host, :canaries, :normalization]
  end

  @doc """
  Observes `path` on both sides. `context` has `:run_prefix`, `:twin_prefix`, `:repo`
  (the unboxed repository) and `:peer` (the external peer's connection, opened outside
  the run). `prior` (optional) runs before each observation, unobserved, in the test
  process, with `%{resource:, prefix:, record:, repo:, peer:, path:}`: a replay's first
  call, a recovery's interrupted first call.
  """
  def observe(%Path{} = path, context, prior \\ nil) do
    canaries = %{short: :crypto.strong_rand_bytes(8), long: :crypto.strong_rand_bytes(32)}

    run = side(path, Withheld, context.run_prefix, context, canaries, prior)
    twin = side(path, Returned, context.twin_prefix, context, canaries, prior)
    {run, twin} = Normalization.align(run, twin)
    %{run: run, twin: twin, path: path}
  end

  @doc "Observes only the executing-only side: the path has no twin."
  def observe_alone(%Path{} = path, context, prior \\ nil) do
    canaries = %{short: :crypto.strong_rand_bytes(8), long: :crypto.strong_rand_bytes(32)}
    side(path, Withheld, context.run_prefix, context, canaries, prior)
  end

  defp side(path, resource, prefix, %{repo: repo, peer: peer}, canaries, prior) do
    record = if path.record, do: seed!(resource, prefix)

    started = System.monotonic_time(:microsecond)

    if prior do
      prior.(%{
        resource: resource,
        prefix: prefix,
        record: record,
        repo: repo,
        peer: peer,
        path: path
      })
    end

    host = host(path, resource)
    before = Persisted.snapshot(prefix)

    prepared = subject(path, resource, prefix, record)
    runtime = Normalization.runtime(prefix)

    setup = fn ->
      Repo.put_dynamic_repo(repo)
      Faults.put_peer(peer)
      Faults.plant(canaries.short, canaries.long)
      Faults.put(path.fault)
      prepared
    end

    run =
      ExitBoundary.observe(setup, invoke(resource, path), %{host: host, callbacks: @callbacks})

    delta = Persisted.delta(before, Persisted.snapshot(prefix))

    normalization =
      Normalization.new(prefix, resource, path, prepared, before, run.events, runtime)
      |> Normalization.payloads(delta)
      |> Map.put(:observed_elapsed, System.monotonic_time(:microsecond) - started)

    %Observation{
      run: run,
      delta: delta,
      prefix: prefix,
      host: host,
      canaries: canaries,
      normalization: normalization
    }
  end

  defp host(%Path{external?: true}, Withheld), do: [External]
  defp host(%Path{external?: true}, Returned), do: [ReturnedExternal]
  defp host(%Path{}, Withheld), do: [Producer]
  defp host(%Path{}, Returned), do: []

  @doc "Seeds one record in `prefix` through the test's connection, committed."
  def seed!(resource, prefix) do
    resource
    |> Ash.Changeset.for_create(:seed, %{amount: 1}, tenant: prefix)
    |> Ash.create!()
  end

  @doc "The path's subject, built for `resource` in `prefix`."
  def subject(%Path{type: :action} = path, resource, prefix, _record) do
    Ash.ActionInput.for_action(resource, path.action, input(path), tenant: prefix)
  end

  def subject(%Path{type: :create} = path, resource, prefix, _record) do
    Ash.Changeset.for_create(resource, path.action, input(path), tenant: prefix)
  end

  def subject(%Path{type: :update} = path, _resource, prefix, record) do
    Ash.Changeset.for_update(record, path.action, input(path), tenant: prefix)
  end

  def subject(%Path{type: :destroy} = path, _resource, prefix, record) do
    Ash.Changeset.for_destroy(record, path.action, input(path), tenant: prefix)
  end

  defp input(path), do: Map.put(path.input, :request_key, path.key)

  # The run calls the boundary function (or, on a direct path, Ash itself); the twin makes
  # the same Ash call `deliver/2` makes, with the same options.
  defp invoke(resource, %Path{transaction: nil} = path), do: &run_call(resource, path, &1)

  #
  # In a caller transaction both sides end it the same way with the same value: what the
  # caller hands the transaction is its own code, and the run's result is read from the
  # traced return of `deliver/2` (`returned/1`).
  defp invoke(Withheld, %Path{transaction: ending} = path) do
    fn subject ->
      Repo.transaction(fn ->
        _result = run_call(Withheld, path, subject)
        end_transaction(ending)
      end)
    end
  end

  defp invoke(Returned, %Path{transaction: ending}) do
    fn _subject -> Repo.transaction(fn -> end_transaction(ending) end) end
  end

  defp end_transaction(:rollback), do: Repo.rollback(:ended)
  defp end_transaction(:commit), do: :ended

  @doc "What `deliver/2` returned to the caller in an observation, from its traced return."
  def returned(%Observation{run: run}) do
    Enum.find_value(run.events, fn
      %Analysis.Event{kind: :frame_return, mfa: {AshOnetime, :deliver, 2}, event: event} ->
        {_pid, :return_from, _mfa, value} = event
        value

      _other ->
        nil
    end)
  end

  @doc "The side's call of `subject`: what a prior call and the observed call both run."
  def run_call(Withheld, %Path{call: :deliver} = path, subject),
    do: AshOnetime.deliver(subject, path.opts)

  def run_call(_resource, path, subject), do: call(subject, path.opts)

  @doc "The Ash call `deliver/2` makes for `subject`."
  def call(%Ash.Changeset{action: %{type: :create}} = changeset, opts),
    do: Ash.create(changeset, opts)

  def call(%Ash.Changeset{action: %{type: :update}} = changeset, opts),
    do: Ash.update(changeset, Keyword.put(opts, :atomic_upgrade?, false))

  def call(%Ash.Changeset{action: %{type: :destroy}} = changeset, opts),
    do: Ash.destroy(changeset, opts)

  def call(%Ash.ActionInput{} = input, opts), do: Ash.run_action(input, opts)

  # ---------------------------------------------------------------------------------
  # The checks.

  @doc """
  X1 to X4 and the searches of a pair. `delivery` is the check of the run's delivery:
  `:executed` (both canaries, by name), or `:replayed` / `:recovered` (no values), or
  `:none` (the run returned no delivery: an error).
  """
  def assert_boundary!(%{run: run, twin: twin, path: path}, delivery) do
    contained!(run, :run)
    contained!(twin, :twin)
    x1!(run, twin)
    x2!(run, twin, path.fault)
    # In a caller transaction the twin does nothing, so the results differ by construction.
    if is_nil(path.transaction), do: x3!(run, twin, path)
    delivery!(run, delivery)
    :ok
  end

  @doc """
  A path with no twin: the containment checks and nothing persisted. `emitted` states what
  else the run may emit: `:nothing` (a refusal before arming: no event outside the
  package's declared events and the host's frames) or `:searched` (Ash ran the action and
  rolled it back: its events are not compared, and the searches cover every one).
  """
  def assert_contained!(%Observation{} = run, delivery, emitted)
      when emitted in [:nothing, :searched] do
    contained!(run, :run)

    if run.delta != %{} do
      flunk!("the run persisted rows", Map.new(run.delta, &table_counts/1))
    end

    if emitted == :nothing do
      case Analysis.emitted(run.run.events, %{host: run.host, package?: true}, run.normalization) do
        empty when map_size(empty) == 0 -> :ok
        events -> flunk!("the run emitted events outside its declared set", descriptors(events))
      end
    end

    delivery!(run, delivery)
    :ok
  end

  # The unclaimed events, the residue, and both searches, in the events and the rows.
  defp contained!(%Observation{run: run} = side, label) do
    case Analysis.unclaimed(run.events) do
      [] -> :ok
      unclaimed -> flunk!("#{label}: events no class claims", unclaimed)
    end

    if run.residue != 0, do: flunk!("#{label}: delivery entries left in the caller", run.residue)

    canaries = Analysis.needles([side.canaries.short, side.canaries.long])
    envelopes = Analysis.envelopes(run.events)

    canaries!(run, canaries, side.host, label)
    envelopes!(run, envelopes, label)
    rows!(side, canaries ++ Analysis.needles(envelopes), label)
  end

  defp canaries!(run, canaries, host, label) do
    case Analysis.hits(run.events, canaries, &Analysis.canary_allowed?(&1, host)) do
      [] -> :ok
      hits -> flunk!("#{label}: a canary crossed the boundary", hits)
    end
  end

  defp envelopes!(_run, [], _label), do: :ok

  defp envelopes!(run, envelopes, label) do
    needles = Analysis.needles(envelopes)

    case Analysis.hits(run.events, needles, &Analysis.envelope_allowed?(&1, envelopes)) do
      [] -> :ok
      hits -> flunk!("#{label}: an envelope crossed the boundary", hits)
    end
  end

  defp rows!(side, needles, label) do
    rows = Persisted.snapshot(side.prefix)

    for {table, table_rows} <- rows, Analysis.contains?(table_rows, needles) do
      flunk!("#{label}: a row carries a canary or an envelope", table)
    end

    :ok
  end

  defp x1!(run, twin) do
    run_delta =
      Persisted.normalize(Normalization.term(run.delta, run.normalization), "<prefix>", %{})

    twin_delta =
      Persisted.normalize(Normalization.term(twin.delta, twin.normalization), "<prefix>", %{})

    case Persisted.difference(run_delta, twin_delta) do
      [] -> :ok
      difference -> flunk!("X1: the persisted projections differ", difference)
    end
  end

  defp x2!(run, twin, fault) do
    run_emitted =
      Analysis.emitted(run.run.events, %{host: run.host, package?: true}, run.normalization)

    twin_emitted =
      Analysis.emitted(twin.run.events, %{host: twin.host, package?: false}, twin.normalization)

    case Analysis.emitted_difference(run_emitted, twin_emitted) do
      [] ->
        :ok

      difference ->
        flunk!(
          "X2: the emitted events differ",
          {fault, Analysis.emitted_divergences(run_emitted, twin_emitted),
           Enum.frequencies_by(difference, fn {{class, descriptor, _}, _, _} ->
             {class, descriptor}
           end)}
        )
    end
  end

  defp x3!(run, twin, path) do
    run_result = run.run.result |> without_delivery()
    twin_result = twin.run.result |> as_delivered(path)

    case Analysis.divergence(
           Analysis.shape(run_result, run.normalization),
           Analysis.shape(twin_result, twin.normalization)
         ) do
      nil -> :ok
      divergence -> flunk!("X3: the caller's results differ", divergence)
    end

    :ok
  end

  defp delivery!(%Observation{run: run, canaries: canaries}, expected) do
    actual = delivery(run.result)

    ok? =
      case {expected, actual} do
        {:executed, %AshOnetime.Delivery{outcome: :executed, values: values}} ->
          values == %{short: canaries.short, long: canaries.long}

        {outcome, %AshOnetime.Delivery{outcome: outcome, values: values}}
        when outcome in [:replayed, :recovered] ->
          values == %{}

        {:none, nil} ->
          true

        _other ->
          false
      end

    if not ok?,
      do: flunk!("X4: the delivery is not the expected one", {expected, outline(actual)})

    :ok
  end

  defp delivery({:ok, {:ok, _result, %AshOnetime.Delivery{}} = inner}), do: delivery(inner)
  defp delivery({:error, {:ok, _result, %AshOnetime.Delivery{}} = inner}), do: delivery(inner)
  defp delivery({:ok, _result, %AshOnetime.Delivery{} = delivery}), do: delivery
  defp delivery({:ok, _result, _notifications, %AshOnetime.Delivery{} = delivery}), do: delivery
  defp delivery(_result), do: nil

  defp without_delivery({:ok, result, %AshOnetime.Delivery{}}), do: {:ok, result}

  defp without_delivery({:ok, result, notifications, %AshOnetime.Delivery{}}),
    do: {:ok, result, notifications}

  defp without_delivery(other), do: other

  # The twin's result in `deliver/2`'s documented form: where Ash returns a bare `:ok`, the
  # call returns `{:ok, nil, delivery}`; a destroy's notifications without the record come
  # as `{:ok, nil, notifications, delivery}`.
  defp as_delivered(:ok, _path), do: {:ok, nil}

  defp as_delivered({:ok, notifications}, %Path{type: :destroy, opts: opts}) do
    if opts[:return_notifications?] && !opts[:return_destroyed?],
      do: {:ok, nil, notifications},
      else: {:ok, notifications}
  end

  defp as_delivered(result, _path), do: result

  # A result's printable outline: its tags and struct names, never a value.
  defp outline({tag, _value}) when is_atom(tag), do: {tag, :_}
  defp outline({tag, value, _rest}) when is_atom(tag), do: {tag, outline(value), :_}
  defp outline({tag, value, _n, _d}) when is_atom(tag), do: {tag, outline(value), :_, :_}
  defp outline(%{__struct__: struct}), do: struct
  defp outline(nil), do: nil
  defp outline(_value), do: :term

  defp table_counts({table, %{added: added, removed: removed}}),
    do: {table, {length(added), length(removed)}}

  defp descriptors(emitted) do
    emitted
    |> Analysis.emitted_difference(%{})
    |> Enum.map(fn {descriptor, count, _zero} -> {descriptor, count} end)
  end

  defp flunk!(message, detail) do
    raise ExUnit.AssertionError, message: "#{message}: #{inspect(detail, limit: :infinity)}"
  end
end
