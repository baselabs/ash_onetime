defmodule AshOnetime.Delivery.NestedClaimTest do
  # §2.7.4's nested-claim matrix, driven through the real `AshOnetime.deliver/2` against
  # the real store. Consumer code runs at every callback Ash runs ahead of the package's
  # entry (a policy check, `repo.prepare_query/3`, a calculation's `load/3`, a
  # `before_transaction` hook) and starts a nested operation of every shape, on every
  # route, in the caller's process, in a Task and through Ash's bulk paths. Every row
  # asserts at most one value per key, the outcome of both calls, the claims that
  # committed, and that no entry is left in the process dictionary.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery
  alias AshOnetime.Test.DeliveryExamples
  alias AshOnetime.Test.DeliveryFacts.Tracer
  alias AshOnetime.Test.DeliveryGuarded.{Consumer, Resource}

  @moduletag executing_only_nested: true

  @routes [:create, :update, :destroy, :soft_destroy, :generic]
  @crud [:create, :update, :destroy, :soft_destroy]
  @callbacks [:policy, :prepare_query, :calculation, :before_transaction]
  @subject_shapes [:a, :deliver_reuse]
  @shapes [:a, :b, :cS, :cC, :deliver_reuse, :deliver_rebuild, :deliver_changed, :deliver_fail]

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)
  end

  # prepare_query/3 and a calculation's load/3 receive no changeset or action input
  # (ecto/repo/queryable.ex:224; ash_sql/bindings.ex:74; query/query.ex:2389;
  # resource/calculation.ex:141), so the shapes that reuse the subject do not exist there.
  for route <- @routes,
      callback <- @callbacks,
      shape <- @shapes,
      callback in [:policy, :before_transaction] or shape not in @subject_shapes do
    @route route
    @hook_callback callback
    @shape shape

    @tag nested_matrix: true, nested_shape: shape
    test "#{route}, #{callback}, shape #{shape}", %{prefix: prefix} do
      row = run_row(prefix, @route, @hook_callback, @shape, nil)
      assert_row(row, expected(@route, @hook_callback, @shape))
    end
  end

  # `Ash.Scope.to_opts/2` on a policy authorizer reads the tracer from the subject's
  # private context and has no other clause (scope.ex:166), so consumer code that hands
  # it the authorizer raises unless a tracer is configured. The matrix runs with one;
  # these rows run without it. Ash re-raises an exception from inside an action rather
  # than returning it (create.ex:124, update.ex:343, destroy.ex:123, action.ex:23), and
  # deliver/2 lets it propagate as Ash does: the outer call raises before the entry, with
  # no claim, no value and no dictionary entry left behind.
  for route <- @routes, shape <- [:cS, :cC] do
    @route route
    @shape shape

    @tag nested_matrix: true, nested_shape: shape
    test "#{route}, policy, shape #{shape}, no tracer", %{prefix: prefix} do
      build = plan_row(prefix, @route, :policy, @shape, nil, nil)

      error =
        assert_raise Ash.Error.Unknown, fn -> AshOnetime.deliver(build.(), authorize?: true) end

      assert Exception.message(error) =~ "Ash.Policy.Authorizer.get_tracer/1"
      {plan, nested} = Consumer.finish()
      assert plan.started?, "the consumer code never received a delivery reference"
      assert nested == nil
      refute_residue()
      assert claim_count(prefix) == 0
    end
  end

  # A Task crossing: the nested operation runs in another process, whose dictionary has
  # no entry. Generic actions with policies authorize inside the transaction
  # (actions/action.ex:180-260), where the sandboxed connection is held by this process,
  # so a generic row crosses from its before_transaction hook only.
  for route <- @routes,
      callback <- [:policy, :before_transaction],
      shape <- [:a, :b],
      route != :generic or callback == :before_transaction do
    @route route
    @hook_callback callback
    @shape shape

    @tag nested_task: true
    test "task crossing: #{route}, #{callback}, shape #{shape}", %{prefix: prefix} do
      row = run_row(prefix, @route, @hook_callback, @shape, :task)

      assert_row(row, %{
        outer: :executed,
        nested: {:error, :executing_only_requires_call},
        claims: 1
      })
    end
  end

  # Ash's bulk paths build each changeset themselves, so each carries a fresh cell; at
  # max_concurrency 2 Ash runs the batch in a worker. Ash has no bulk path for generic
  # actions. Update and destroy cannot run atomically: the package's change returns
  # :not_atomic, so the atomic strategies end in NoMatchingBulkStrategy.
  for route <- @crud,
      callback <- @callbacks,
      {strategy, input} <-
        if(route == :create,
          do: [{:native, :none}],
          else: [
            {:stream, :query},
            {:stream, :records},
            {:atomic, :query},
            {:atomic_batches, :query}
          ]
        ),
      concurrency <- [0, 2] do
    @route route
    @hook_callback callback
    @bulk {:bulk, strategy, concurrency, input}

    @tag nested_bulk: true
    test "bulk crossing: #{route}, #{callback}, #{strategy} over #{input}, concurrency #{concurrency}",
         %{prefix: prefix} do
      row = run_row(prefix, @route, @hook_callback, @bulk, nil)
      {:bulk, strategy, concurrency, _input} = @bulk

      assert %Delivery{outcome: :executed} = delivery(row.outer)
      assert row.claims == 1
      assert %Ash.BulkResult{status: :error, errors: [_ | _] = errors} = row.nested

      codes = Enum.map(errors, &AshOnetime.Error.code/1)

      cond do
        strategy in [:atomic, :atomic_batches] ->
          assert Enum.all?(codes, &is_nil/1)

        concurrency == 0 ->
          assert Enum.all?(codes, &(&1 == :executing_only_refused))

        true ->
          assert Enum.all?(codes, &(&1 == :executing_only_requires_call))
      end
    end
  end

  # The limit (§2.7.5, the spent entry): code in the caller's pipeline that runs the action
  # on the built subject spends the claim. The outer call returns `:executing_only_lost`,
  # the effect happened once, and it is on the recovery path: a retry under the same key
  # finds the completion and replays it with no value. A hard destroy's retry meets the
  # row the effect removed first, in Ash's filter authorization (actions/destroy/
  # destroy.ex:150), and returns Ash's own error for it.
  describe "the limit" do
    for route <- @routes do
      @route route

      @tag nested_limit: true
      test "#{route}: a spent claim is lost, and the retry finds the effect with no value", %{
        prefix: prefix
      } do
        build = plan_row(prefix, @route, :before_transaction, :a, nil, Tracer)
        outer = AshOnetime.deliver(build.(), authorize?: true)
        {plan, nested} = Consumer.finish()

        assert plan.started?, "the consumer code never received a delivery reference"
        assert outcome(outer) == :lost
        assert nested_outcome(nested) == :ok
        assert claim_count(prefix) == 1

        retry = AshOnetime.deliver(build.(), authorize?: true)
        assert outcome(retry) == if(@route == :destroy, do: :forbidden, else: :replayed)
        assert claim_count(prefix) == 1

        assert_at_most_one_value([outer, nested, retry])
        refute_residue()
      end
    end
  end

  describe "the entry" do
    for route <- @routes do
      @route route

      @tag nested_wrong_pid: true
      test "#{route}: an armed entry under the right H(ref) for another pid is refused", %{
        prefix: prefix
      } do
        other = spawn(fn -> :ok end)

        subject =
          prefix
          |> builder(@route, unique_key("wrong-pid"))
          |> then(& &1.())
          |> hook(
            :before_transaction,
            fn pending ->
              key = hashed_key(pending)
              {:armed, _pid, resource, action, cell, public} = Process.get(key)
              Process.put(key, {:armed, other, resource, action, cell, public})
              pending
            end,
            []
          )

        result = AshOnetime.deliver(subject)

        assert error_code(result) == :executing_only_refused
        assert claim_count(prefix) == 0
        assert_at_most_one_value([result])
        refute_residue()
      end

      @tag nested_hash_key: true
      test "#{route}: the entry lives under H(ref), and no dictionary key holds the reference",
           %{prefix: prefix} do
        subject =
          prefix
          |> builder(@route, unique_key("hash-key"))
          |> then(& &1.())
          |> hook(
            :before_transaction,
            fn pending ->
              ref = pending.context.private.ash_onetime_delivery.ref

              armed? =
                match?(
                  {:armed, pid, _, _, _, _} when pid == self(),
                  Process.get(hashed_key(pending))
                )

              raw? =
                Enum.any?(Process.get_keys(), fn key ->
                  :binary.match(:erlang.term_to_binary(key), ref) != :nomatch
                end)

              send(self(), {:entry, armed?, raw?})
              pending
            end,
            []
          )

        result = AshOnetime.deliver(subject)

        assert_received {:entry, true, false}
        assert %Delivery{outcome: :executed} = delivery(result)
        refute_residue()
      end

      @tag nested_rule_one: true
      test "#{route}: entry facts placed in the subject's context are never read", %{
        prefix: prefix
      } do
        {foreign_public, _foreign_secret} = :crypto.generate_key(:ecdh, :x25519)

        foreign = %{
          public_key: foreign_public,
          public: foreign_public,
          pid: spawn(fn -> :ok end),
          resource: DeliveryExamples.Outer,
          action: :outer,
          cell: make_ref(),
          ash_onetime_delivery_cell: make_ref()
        }

        subject =
          prefix
          |> builder(@route, unique_key("rule-one"))
          |> then(& &1.())
          |> hook(
            :before_transaction,
            fn pending ->
              set_context(
                pending,
                Map.merge(foreign, %{
                  shared: foreign,
                  private: %{ash_onetime_delivery: foreign}
                })
              )
            end,
            []
          )

        result = AshOnetime.deliver(subject)

        assert %Delivery{outcome: :executed, values: %{secret: secret}} = delivery(result)
        assert byte_size(secret) == 32
        assert claim_count(prefix) == 1
        refute_residue()
      end

      @tag nested_cell: true
      test "#{route}: a cell replaced in the subject before the call fails closed", %{
        prefix: prefix
      } do
        subject =
          prefix
          |> builder(@route, unique_key("cell-replaced"))
          |> then(& &1.())
          |> set_context(%{private: %{ash_onetime_delivery_cell: make_ref()}})

        result = AshOnetime.deliver(subject)

        assert error_code(result) == :executing_only_refused
        assert claim_count(prefix) == 0
        refute_residue()
      end
    end
  end

  # The expected outcome of each matrix row (§2.7.4, decisions 1 and 3). A CRUD action
  # authorizes and runs before_transaction hooks outside its transaction
  # (actions/update/update.ex:359-362), so a nested operation there commits or fails on
  # its own. A generic action with `transaction? true` authorizes inside its transaction
  # (actions/action.ex:180-260): a nested Ash call joins it inline
  # (data_layer.ex:640-641), and a nested failure rolls the whole transaction back, so
  # the outer call fails with the nested error and nothing commits.
  defp expected(route, callback, shape) do
    inside? = route == :generic and callback != :before_transaction

    # A hard destroy whose record the nested call removed fails the outer's filter
    # authorization (actions/destroy/destroy.ex:150).
    removed? = route == :destroy and callback != :before_transaction

    if inside?, do: inside_transaction(shape), else: outside_transaction(shape, removed?)
  end

  defp outside_transaction(:a, removed?),
    do: %{outer: if(removed?, do: :forbidden, else: :lost), nested: :ok, claims: 1}

  defp outside_transaction(:b, _removed?),
    do: %{outer: :executed, nested: {:error, :executing_only_refused}, claims: 1}

  defp outside_transaction(shape, _removed?) when shape in [:cS, :cC],
    do: %{outer: :executed, nested: {:error, :executing_only_requires_call}, claims: 1}

  defp outside_transaction(shape, removed?) when shape in [:deliver_reuse, :deliver_rebuild],
    do: %{outer: if(removed?, do: :forbidden, else: :replayed), nested: :executed, claims: 1}

  defp outside_transaction(:deliver_changed, removed?) do
    outer = if removed?, do: :forbidden, else: {:error, :key_reused_with_different_request}
    %{outer: outer, nested: :executed, claims: 1}
  end

  defp outside_transaction(:deliver_fail, _removed?),
    do: %{outer: :executed, nested: :failed, claims: 1}

  defp inside_transaction(:a), do: %{outer: :lost, nested: :ok, claims: 0}

  defp inside_transaction(:b),
    do: %{outer: {:error, :executing_only_refused}, nested: nil, claims: 0}

  defp inside_transaction(shape) when shape in [:cS, :cC],
    do: %{outer: {:error, :executing_only_requires_call}, nested: nil, claims: 0}

  defp inside_transaction(_deliver),
    do: %{outer: :executed, nested: {:error, :executing_only_in_transaction}, claims: 1}

  # The producer reports each production in this process (the fact, never the value), so
  # a row counts the productions both calls made here.
  defp run_row(prefix, route, callback, shape, crossing) do
    build = plan_row(prefix, route, callback, shape, crossing, Tracer)
    observer = {DeliveryExamples.Producer, :observer}
    Process.put(observer, self())

    outer =
      try do
        AshOnetime.deliver(build.(), authorize?: true)
      after
        Process.delete(observer)
      end

    {plan, nested} = Consumer.finish()

    assert plan.started?, "the consumer code never received a delivery reference"
    assert_at_most_one_value([outer, nested])
    refute_residue()

    %{outer: outer, nested: nested, claims: claim_count(prefix), produced: productions(0)}
  end

  defp productions(count) do
    me = self()

    receive do
      {:produced, ^me, _keys} -> productions(count + 1)
    after
      0 -> count
    end
  end

  defp plan_row(prefix, route, callback, shape, crossing, tracer) do
    %{build: build, record: record, params: params} =
      guarded(prefix, route, unique_key("nested-#{route}-#{callback}"), tracer)

    Consumer.plan!(%{
      route: route,
      callback: callback,
      shape: shape,
      crossing: crossing,
      tenant: prefix,
      record: record,
      params: params
    })

    build
  end

  # The comparisons print only outcomes and counts, never the results themselves. A
  # replay produces nothing: the one production is the nested call's execution, even
  # though finalize would drop values sealed on a replay.
  defp assert_row(row, expected) do
    assert outcome(row.outer) == expected.outer
    assert nested_outcome(row.nested) == expected.nested
    assert row.claims == expected.claims

    if expected.outer == :replayed do
      assert row.produced == 1
    end
  end

  defp outcome({:error, %Ash.Error.Forbidden{}}), do: :forbidden
  defp outcome({:error, _error} = error), do: error_lost(error)

  defp outcome(result) when is_tuple(result) do
    case delivery(result) do
      %Delivery{outcome: :executed, values: %{secret: secret}} when is_binary(secret) -> :executed
      %Delivery{outcome: outcome, values: values} when values == %{} -> outcome
    end
  end

  defp error_lost(error) do
    case error_code(error) do
      :executing_only_lost -> :lost
      code -> {:error, code}
    end
  end

  defp nested_outcome(nil), do: nil

  defp nested_outcome({:error, _error} = error) do
    case error_code(error) do
      nil -> :failed
      code -> {:error, code}
    end
  end

  defp nested_outcome(result) when is_tuple(result) do
    case delivery(result) do
      %Delivery{outcome: :executed} -> :executed
      _plain -> :ok
    end
  end

  defp nested_outcome(:ok), do: :ok

  defp delivery(result) when is_tuple(result) and tuple_size(result) > 2,
    do: elem(result, tuple_size(result) - 1)

  defp delivery(_result), do: nil

  # The outer subject carries a tracer in its private context, as an application with
  # tracing configured has, unless the row runs without one.
  defp guarded(prefix, route, key, tracer) do
    record =
      if route in [:update, :destroy, :soft_destroy] do
        Resource
        |> Ash.Changeset.for_create(:seed, %{amount: 1}, tenant: prefix)
        |> Ash.create!(authorize?: false)
      end

    params = params(route, key)
    opts = if tracer, do: [tenant: prefix, tracer: tracer], else: [tenant: prefix]

    %{
      build: fn -> guarded_subject(route, record, params, opts) end,
      record: record,
      params: params
    }
  end

  defp params(:create, key), do: %{amount: 1, request_key: key}
  defp params(:update, key), do: %{amount: 2, request_key: key}
  defp params(:generic, key), do: %{value: 1, request_key: key}
  defp params(_destroy, key), do: %{request_key: key}

  defp guarded_subject(:create, nil, params, opts),
    do: Ash.Changeset.for_create(Resource, :issue, params, opts)

  defp guarded_subject(:update, record, params, opts),
    do: Ash.Changeset.for_update(record, :rotate, params, opts)

  defp guarded_subject(:destroy, record, params, opts),
    do: Ash.Changeset.for_destroy(record, :revoke, params, opts)

  defp guarded_subject(:soft_destroy, record, params, opts),
    do: Ash.Changeset.for_destroy(record, :retire, params, opts)

  defp guarded_subject(:generic, nil, params, opts),
    do: Ash.ActionInput.for_action(Resource, :mint, params, opts)

  # The entry's dictionary key, computed here from the reference rather than through the
  # package, so a change to how the package derives it fails these tests.
  defp hashed_key(subject) do
    ref = subject.context.private.ash_onetime_delivery.ref
    {Delivery, :crypto.hash(:sha256, ref)}
  end

  defp set_context(%Ash.Changeset{} = changeset, context),
    do: Ash.Changeset.set_context(changeset, context)

  defp set_context(%Ash.ActionInput{} = input, context),
    do: Ash.ActionInput.set_context(input, context)

  defp refute_residue do
    assert Enum.filter(Process.get_keys(), &match?({Delivery, _}, &1)) == [],
           "a delivery entry was left in the process dictionary"
  end
end
