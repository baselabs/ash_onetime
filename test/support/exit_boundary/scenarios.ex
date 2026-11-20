defmodule AshOnetime.Test.ExitBoundary.Scenarios do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary

  alias AshOnetime.Test.ExitBoundary.{
    Codec,
    Consumer,
    Faults,
    Hold,
    Pair,
    Persisted,
    Producer,
    Recorder,
    ResponseClassifier
  }

  alias AshOnetime.Test.ExitBoundary.{
    External,
    Returned,
    ReturnedExternal,
    Withheld,
    Hooks,
    References
  }

  alias AshOnetime.Test.Repo
  alias Ecto.Adapters.SQL

  @routes [
    %{action: :issue, type: :create, input: %{amount: 7}, record: false},
    %{action: :rotate, type: :update, input: %{amount: 7}, record: true},
    %{action: :revoke, type: :destroy, input: %{}, record: true},
    %{action: :retire, type: :destroy, input: %{}, record: true},
    %{action: :mint, type: :action, input: %{value: 7}, record: false}
  ]
  @callbacks [Codec, Consumer, Hold, Recorder, ResponseClassifier, AshOnetime.Test.ExternalPeer]
  @external %{
    issue: :external_issue,
    rotate: :external_rotate,
    revoke: :external_revoke,
    retire: :external_retire,
    mint: :external_mint
  }

  def rows do
    for route <- @routes, external? <- [false, true], path <- paths(external?) do
      route
      |> Map.merge(path)
      |> Map.put(:external?, external?)
      |> Map.update!(:action, fn name -> if external?, do: @external[name], else: name end)
      |> Map.put(:key, "bound-twin")
    end
  end

  defp paths(external?) do
    common = [
      %{branch: :execute, fault: nil},
      %{branch: :replay, fault: nil},
      %{branch: :failure, fault: :classify_reject},
      %{branch: :failure, fault: :classify_rollback},
      %{branch: :failure, fault: :codec_encode},
      %{branch: :failure, fault: :codec_decode},
      %{branch: :failure, fault: :hold_invalid},
      %{branch: :failure, fault: :store_completion},
      %{branch: :transaction, fault: :commit},
      %{branch: :transaction, fault: :rollback},
      %{branch: :consumer_failure, fault: :after_raise},
      %{branch: :consumer_failure, fault: :after_exit},
      %{branch: :consumer_failure, fault: :after_throw},
      %{branch: :direct, fault: nil}
    ]

    if external? do
      common ++
        [
          %{branch: :recovered, fault: nil},
          %{branch: :recovery_absent, fault: nil},
          %{branch: :finalize_replay, fault: :finalize_replay},
          %{branch: :unknown, fault: :execute_unknown}
        ]
    else
      common ++
        for fault <- [:producer_raise, :producer_error, :producer_contract],
            do: %{branch: :producer_failure, fault: fault}
    end
  end

  def observe(row, values, context) do
    # The same fixture installation is reset between sides. SQL identifiers therefore
    # compare literally; tenant names never need a string substitution rule.
    {run, twin} =
      if Map.get(context, :run_first?, false) do
        run = side(row, values, Withheld, context)
        between(context, run)
        {run, side(row, values, Returned, context)}
      else
        twin = side(row, values, Returned, context)
        between(context, twin)
        {side(row, values, Withheld, context), twin}
      end

    %{run: run, twin: twin, row: row}
  end

  defp between(context, side) do
    if callback = Map.get(context, :between_sides), do: callback.(side)
  end

  defp side(row, values, resource, context) do
    reset!(context.prefix)

    path =
      struct!(
        Pair.Path,
        Map.take(row, [:action, :type, :input, :record, :key, :external?, :opts])
      )

    record =
      if row.record do
        resource
        |> Ash.Changeset.for_create(:seed, %{amount: 1}, tenant: context.prefix)
        |> Ash.Changeset.force_change_attribute(:id, "00000000-0000-4000-8000-000000000007")
        |> Ash.create!()
      end

    prior = prior(row, values, resource, path, record, context)
    if row.fault == :store_completion, do: move_payloads!(context.prefix, :away)

    try do
      before = Persisted.snapshot(context.prefix, Repo.get_dynamic_repo())
      protection = AshOnetime.Resource.Info.protection(resource, row.action)
      operation_reference = Map.fetch!(context.operation_references, {resource, row.action})
      protection_reference = References.protection(resource, row.action)
      contract_reference = References.contract(resource, row.action, context.prefix)
      hooks = Hooks.reference(resource, row.action, row.type)
      canonical = Hooks.reference(Returned, row.action, row.type)
      historical = AshOnetime.Test.ExitBoundary.Historical.capture(context.prefix)

      prepared =
        if row.branch in [:transaction, :direct] do
          ExitBoundary.observe(
            fn ->
              Repo.put_dynamic_repo(context.repo)
              Faults.put_peer(context.peer)
              Faults.put(row.fault)
              %{resource: resource, prefix: context.prefix, row: row, path: path, record: record}
            end,
            &subject/1,
            %{host: [], callbacks: @callbacks}
          )
        end

      fixture_bindings =
        if prepared do
          for %{event: {_, :return_from, {:erlang, :make_ref, 0}, cell}, stack: stack} <-
                prepared.events,
              {AshOnetime.Delivery, :put_cell, 1} in stack,
              into: %{},
              do: {:cell, cell}
        else
          %{}
        end

      setup = fn ->
        Repo.put_dynamic_repo(context.repo)
        Faults.put_peer(context.peer)
        Process.put({Faults, :canaries}, nil)
        if resource == Withheld, do: Faults.plant(values.short, values.long)
        Faults.put(row.fault)

        input = %{
          resource: resource,
          prefix: context.prefix,
          row: row,
          path: path,
          record: record
        }

        if prepared, do: Map.put(input, :built, prepared.result), else: input
      end

      host = if row.external?, do: [External, ReturnedExternal], else: [Producer]

      run =
        ExitBoundary.observe(setup, &invoke/1, %{
          host: host,
          callbacks: @callbacks,
          include_pure?: Map.get(context, :include_pure?, false)
        })

      %{
        run: run,
        delta:
          Persisted.delta(before, Persisted.snapshot(context.prefix, Repo.get_dynamic_repo())),
        resource: resource,
        row: row,
        values: values,
        protection: protection,
        prior: prior,
        hooks: hooks,
        operation_reference: operation_reference,
        hook_frames:
          AshOnetime.Test.ExitBoundary.FailureTwins.side_frames(hooks, canonical, row, resource),
        prefix: context.prefix,
        historical: historical,
        before: before,
        fixture_bindings: fixture_bindings,
        prepared_subject: if(prepared, do: prepared.result, else: nil),
        setup_events: if(prepared, do: prepared.events, else: []),
        protection_reference: protection_reference,
        contract_reference: contract_reference
      }
      |> AshOnetime.Test.ExitBoundary.Readback.prepare()
    after
      if row.fault == :store_completion, do: move_payloads!(context.prefix, :back)
    end
  end

  def invoke(%{row: %{branch: :transaction} = row, resource: resource} = input) do
    Repo.transaction(fn ->
      Process.info(self(), :current_stacktrace)

      if resource == Withheld do
        AshOnetime.deliver(input.built)
      end

      if row.fault == :rollback, do: Repo.rollback(:ended), else: :ended
    end)
  end

  def invoke(input) do
    built =
      case Map.fetch(input, :built) do
        {:ok, built} -> built
        :error -> subject(input)
      end

    result =
      Pair.run_call(
        input.resource,
        %{input.path | call: if(input.row.branch == :direct, do: :direct, else: :deliver)},
        built
      )

    if Map.get(input.row, :release_hold?, false) do
      target = AshOnetime.Store.Postgres.for_repo(Repo, input.prefix)

      {:ok, {:ok, 1}} =
        Repo.transaction(fn ->
          AshOnetime.Transaction.release(Repo,
            prefix: input.prefix,
            partition: target.logical_partition,
            reference: "boundary-hold"
          )
        end)

      columns =
        "id, logical_partition, operation_hash, scope_hash, key_hash, fingerprint, state, response_partition, response_codec, response_digest, hold_reference, admitted_at, retain_until, inserted_at"

      SQL.query!(
        Repo.get_dynamic_repo(),
        ~s[SELECT #{columns} FROM "#{input.prefix}".ash_onetime_idempotency_claims],
        []
      )
    end

    result
  end

  defp subject(input) do
    built = Pair.subject(input.path, input.resource, input.prefix, input.record)

    if input.row.branch in [:producer_failure, :direct] do
      error = AshOnetime.Test.ExitBoundary.FailureTwins.error(input.row.branch)
      AshOnetime.Test.ExitBoundary.FailureTwins.install(built, input.row, error)
    else
      built
    end
  end

  defp prior(row, values, resource, path, record, context) do
    cond do
      row.branch == :replay or row.fault == :codec_decode ->
        # The first call is itself observed. Identities and database values in a
        # replay are carried forward from that call, never inferred from its row.
        side(%{row | branch: :execute, fault: nil}, values, resource, context)

      row.branch in [:recovered, :recovery_absent] ->
        interrupted(row, values, resource, path, record, context)

      true ->
        nil
    end
  end

  defp interrupted(row, values, resource, path, record, context) do
    before = Persisted.snapshot(context.prefix, Repo.get_dynamic_repo())
    historical = AshOnetime.Test.ExitBoundary.Historical.capture(context.prefix)
    point = if row.branch == :recovered, do: :after_execute, else: :before_execute
    prior_row = %{row | branch: :interrupted, fault: point}

    run =
      ExitBoundary.observe(
        fn ->
          prepare_worker(context)
          if resource == Withheld, do: Faults.plant(values.short, values.long)
          Faults.put({:interrupt, point})
          %{resource: resource, prefix: context.prefix, path: path, record: record}
        end,
        fn input ->
          Pair.run_call(
            input.resource,
            input.path,
            Pair.subject(input.path, input.resource, input.prefix, input.record)
          )
        end,
        %{host: [External, ReturnedExternal], callbacks: @callbacks}
      )

    hooks = Hooks.reference(resource, row.action, row.type)

    %{
      run: run,
      resource: resource,
      row: prior_row,
      values: values,
      prefix: context.prefix,
      historical: historical,
      before: before,
      prior: nil,
      delta: Persisted.delta(before, Persisted.snapshot(context.prefix, Repo.get_dynamic_repo())),
      protection: AshOnetime.Resource.Info.protection(resource, row.action),
      operation_reference: Map.fetch!(context.operation_references, {resource, row.action}),
      protection_reference: References.protection(resource, row.action),
      contract_reference: References.contract(resource, row.action, context.prefix),
      hooks: hooks,
      hook_frames: Hooks.frames(hooks, Hooks.reference(Returned, row.action, row.type)),
      fixture_bindings: %{},
      setup_events: []
    }
  end

  defp prepare_worker(context) do
    Repo.put_dynamic_repo(context.repo)
    Faults.put_peer(context.peer)
    Faults.put(nil)
  end

  def reset!(prefix) do
    %{rows: tables} =
      SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT tablename FROM pg_tables t WHERE schemaname = $1 AND NOT EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname = t.tablename AND n.nspname = t.schemaname)",
        [prefix]
      )

    names = Enum.map_join(tables, ", ", fn [name] -> ~s("#{prefix}"."#{name}") end)

    if names != "",
      do:
        SQL.query!(
          Repo.get_dynamic_repo(),
          "TRUNCATE " <> names <> " RESTART IDENTITY CASCADE",
          []
        )

    if :ets.whereis(AshOnetime.Cache.Ets) != :undefined do
      for {key, _, _} <- :ets.tab2list(AshOnetime.Cache.Ets), do: AshOnetime.Cache.Ets.delete(key)
    end
  end

  defp move_payloads!(prefix, direction) do
    {from, to} =
      if direction == :away,
        do: {"ash_onetime_response_payloads", "ash_onetime_response_payloads_moved"},
        else: {"ash_onetime_response_payloads_moved", "ash_onetime_response_payloads"}

    SQL.query!(
      Repo.get_dynamic_repo(),
      ~s(ALTER TABLE "#{prefix}"."#{from}" RENAME TO "#{to}"),
      []
    )
  end
end
