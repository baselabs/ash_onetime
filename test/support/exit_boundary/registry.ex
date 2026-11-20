defmodule AshOnetime.Test.ExitBoundary.Registry do
  @moduledoc false

  alias AshOnetime.Test.ExitBoundary.{External, Returned, ReturnedExternal, Withheld}

  @generators [
                {:crypto, :generate_key, 2},
                {:crypto, :generate_key, 3},
                {:crypto, :strong_rand_bytes, 1},
                {:erlang, :make_ref, 0},
                {:erlang, :monitor, 2},
                {:erlang, :monitor, 3},
                {:erlang, :unique_integer, 0},
                {:erlang, :unique_integer, 1},
                {System, :unique_integer, 1},
                {Ecto.UUID, :generate, 0},
                {Ecto.UUID, :bingenerate, 0},
                {Ash.UUID, :generate, 0},
                {:erlang, :open_port, 2},
                {:erts_internal, :open_port, 2}
              ] ++
                for(
                  function <- [:send_after, :start_timer],
                  arity <- [3, 4],
                  do: {:erlang, function, arity}
                ) ++
                for(
                  function <- [:spawn, :spawn_link, :spawn_monitor],
                  arity <- 1..4,
                  do: {:erlang, function, arity}
                ) ++
                for(arity <- 2..5, do: {:erlang, :spawn_opt, arity}) ++
                for(arity <- 1..5, do: {:erlang, :spawn_request, arity}) ++
                [{:erts_internal, :spawn_request, 4}, {:erts_internal, :spawn_system_process, 3}]
  @clocks for(
            function <- [:monotonic_time, :system_time, :os_time],
            arity <- [0, 1],
            do: {System, function, arity}
          ) ++
            for(
              function <- [:monotonic_time, :system_time],
              arity <- [0, 1],
              do: {:erlang, function, arity}
            ) ++
            for(arity <- [0, 1], do: {:os, :system_time, arity})
  @clock_frames @clocks ++
                  [{:erlang, :timestamp, 0}, {DateTime, :utc_now, 0}, {DateTime, :utc_now, 1}]

  @declarations [
    {AshOnetime.Resource.Info, :protections, 1},
    {Ash.Resource.Info, :actions, 1},
    {Ash.Resource.Info, :attributes, 1},
    {Ash.Resource.Info, :identities, 1},
    {Ash.Resource.Info, :relationships, 1},
    {Ash.Resource.Info, :calculations, 1},
    {Ash.Resource.Info, :aggregates, 1}
  ]

  @database_statements %{
    claim: %{
      table: "ash_onetime_idempotency_claims",
      columns:
        ~w(id logical_partition operation_hash scope_hash key_hash fingerprint state response_partition response_codec response_digest hold_reference admitted_at retain_until inserted_at),
      clocks: ~w(admitted_at retain_until inserted_at),
      sources: [
        {AshOnetime.Store.Postgres, :insert_claim, 3},
        {AshOnetime.Store.Postgres, :update_complete, 7},
        {AshOnetime.Store.Postgres, :release_query, 2}
      ]
    },
    peer: %{
      tables:
        ~w(external_peer_calls external_peer_operations external_peer_effects external_local_effects),
      clocks: ["inserted_at"]
    },
    date: %{
      statements: ["SELECT transaction_timestamp()::date", "SELECT statement_timestamp()::date"],
      columns: ["date"],
      source: {AshOnetime.Store.Postgres, :database_date, 2}
    }
  }

  @function_slots %{
    {Ecto.Adapters.SQL, :"-with_log/4-fun-0-"} => %{2 => :parameters},
    {AshOnetime.Store.Postgres, :"-complete_mode/7-fun-1-"} => %{
      2 => {:response, :codec},
      3 => {:response, :digest},
      4 => {:response, :payload}
    },
    {AshOnetime.Store.Postgres, :"-complete_external/7-fun-1-"} => %{
      2 => {:response, :codec},
      3 => {:response, :digest},
      4 => {:response, :payload}
    },
    {AshOnetime.Store.Postgres, :"-complete_transaction/7-fun-1-"} => %{
      2 => {:response, :payload}
    },
    {AshOnetime.Store.Postgres, :"-complete_transaction/7-fun-2-"} => %{
      2 => {:response, :codec},
      3 => {:response, :digest}
    },
    {AshOnetime.Test.ExternalPeer, :"-execute/4-fun-0-"} => %{1 => :uuid},
    {AshOnetime.Test.ExternalPeer, :"-execute/4-fun-1-"} => %{1 => :uuid},
    {AshOnetime.Test.ExternalPeer, :"-recover/4-fun-0-"} => %{1 => :uuid},
    {AshOnetime.Cache, :"-invoke/3-fun-0-"} => %{1 => :cache_arguments}
  }

  # Sources, locations and expressions live together. A rule is not a predicate over
  # the width, spelling or value of an otherwise unrelated term.
  @rules [
    %{
      id: :o1,
      source: :return,
      locations: [:origin_return],
      expression: :occurrence,
      sources: @generators
    },
    %{
      id: :o2,
      source: :o1,
      locations: [:identity_term, :uuid_column, :table_oid],
      expression: :bijection,
      rename: %{Withheld => Returned, External => ReturnedExternal}
    },
    %{
      id: :attribute_copy,
      source: {AshOnetime.Admission, :reject_reserved, 1},
      locations: [
        {{AshOnetime.Admission, :reserved_surface?, 1}, 0},
        {{AshOnetime.Admission, :"-reserved_surface?/1-fun-0-", 2}, 1}
      ],
      expression: :ordered_subject_surfaces,
      compute: {AshOnetime.Test.ExitBoundary.AttributeCopies, :build, 2}
    },
    %{
      id: :o2a_operation,
      source: {AshOnetime.Fingerprint, :compute, 1},
      locations: [:operation_hash],
      expression: :operation,
      compute: {AshOnetime.Fingerprint, :compute, 1}
    },
    %{
      id: :o2a_context,
      source: {AshOnetime.Delivery.Envelope, :context, 4},
      locations: [:envelope_context],
      expression: :context,
      compute: {AshOnetime.Delivery.Envelope, :context, 4}
    },
    %{
      id: :o2a_computations,
      source: :paired_arguments,
      locations: [:computation_return, :computation_copy, :function_environment],
      expression: :native_computation,
      sources: [
        {AshOnetime.Response, :contract, 4},
        {AshOnetime.Response, :encode, 3},
        {AshOnetime.Response, :replay, 3},
        {AshOnetime.Cache, :key, 1},
        {AshOnetime.Store.Claim.Request, :__struct__, 1},
        {AshOnetime.Store.Claim, :__struct__, 1},
        {AshOnetime.Store.Result, :__struct__, 1},
        {AshOnetime.Admission.State, :__struct__, 1},
        {AshOnetime.Cache.Entry, :__struct__, 1},
        {AshOnetime.Response.Contract, :__struct__, 1}
      ],
      function_slots: @function_slots,
      compute: {AshOnetime.Test.ExitBoundary.Derivations, :build, 2}
    },
    %{
      id: :o2a_diagnostic,
      source: :ash_action_entry,
      locations: [:error_bread_crumb],
      expression: :resource_action_diagnostic,
      entries: %{
        create: {Ash.Actions.Create, :run, 4},
        update: {Ash.Actions.Update, :run, 4},
        destroy: {Ash.Actions.Destroy, :run, 4},
        action: {Ash.Actions.Action, :run, 3}
      }
    },
    %{
      id: :o2b,
      source: :compiled_reader,
      locations: [:declaration],
      expression: :declaration,
      readers: @declarations,
      fields: {AshOnetime.Test.ExitBoundary.DeclarationSlots, :all, 0}
    },
    %{
      id: :o2b_response,
      source: {AshOnetime.Resource.Info, :protection, 2},
      locations: [:compiled_response_declaration],
      expression: :response_field,
      compute: {AshOnetime.Resource.Info, :protection, 2}
    },
    %{
      id: :o2b_argument,
      source: {Ash.Resource.Info, :action, 2},
      locations: [:compiled_action_argument],
      expression: :named_argument,
      compute: {Ash.Resource.Info, :action, 2}
    },
    %{
      id: :o2c,
      source: :installer,
      locations: [:installed_hook],
      expression: :hook,
      installers: %{
        action: {AshOnetime.GenericAction, :prepare, 3},
        crud: {AshOnetime.Change, :change, 3}
      },
      slots: %{action: [before_action: 0, after_action: 1], crud: [around_action: 0]}
    },
    %{
      id: :o5a,
      source: :beam_debug_info,
      locations: [:diagnostic_stack],
      expression: :insert_path_frames,
      compute: {AshOnetime.Test.ExitBoundary.PathFrames, :build, 2}
    },
    %{
      id: :context,
      source: [:ref, :cell],
      locations: [:action_subject_private],
      expression: :private
    },
    %{
      id: :context_copy,
      source: :before_action_input,
      locations: [:implementation_source_context],
      expression: :context_copy,
      slots: [{AshOnetime.GenericAction, :run, 3}, {AshOnetime.GenericAction, :run_original, 3}]
    },
    %{
      id: :return,
      source: :raw_ash_return,
      locations: [:delivered_return],
      expression: :contract_table,
      compute: {AshOnetime.Test.ExitBoundary.Returns, :delivered, 4}
    },
    %{
      id: :claim,
      source: [:key, :ref, :inv, :resource, :action, :names],
      locations: [:delivery_handle],
      expression: :handle,
      slots: %{
        {AshOnetime.Change, :reserve, 4} => 3,
        {AshOnetime.GenericAction, :reserve, 4} => 3,
        {AshOnetime.Admission, :dispatch_reservation, 4} => 3,
        {AshOnetime.ExternalRecovery, :reserve, 4} => 3,
        {AshOnetime.ExternalRecovery, :continue, 6} => 5,
        {AshOnetime.ExternalRecovery, :recover_processing, 7} => 6,
        {AshOnetime.ExternalRecovery, :execute_then_settle, 7} => 6,
        {AshOnetime.ExternalRecovery, :safe_execute, 5} => 4
      }
    },
    %{
      id: :o3,
      source: :clock_return,
      locations: [:clock_return, :clock_expression],
      expression: :clock,
      sources: @clock_frames,
      compute: {AshOnetime.Test.ExitBoundary.ClockExpressions, :build, 2}
    },
    %{
      id: :o4,
      source: :statement,
      locations: [:column, :column_copy],
      expression: :statement,
      statements: @database_statements,
      compute: {AshOnetime.Test.ExitBoundary.DatabaseOrigins, :build, 2}
    },
    %{id: :o5, source: :literal, locations: [:otherwise], expression: :exact},
    %{
      id: :down_flush,
      source: {:erlang, :monitor},
      locations: [:receive],
      expression: :demonitor_flush,
      alternatives: [:received_and_flushed, :absent_and_flushed]
    },
    %{
      id: :inet_reply,
      source: {:erlang, :port_command},
      locations: [:receive],
      expression: :command_reply,
      alternatives: [:reply_before_return, :reply_at_return]
    },
    %{
      id: :deferred_port,
      source: {:erts_internal, :port_command},
      locations: [:receive],
      expression: :command_reply,
      alternatives: [:immediate_result, :reference_then_same_result]
    },
    %{
      id: :inet_async,
      source: {:prim_inet, :async_recv, 3},
      locations: [:receive, :port_send],
      expression: :receive_command_reply,
      alternatives: [:reply_before_recv0_return, :reply_at_recv0_return]
    },
    %{
      id: :task_startup,
      source: {:erlang, :spawn_opt},
      locations: [:receive],
      expression: :spawn_send_receive,
      alternatives: [:startup_after_spawned, :startup_at_spawned]
    },
    %{
      id: :task_unlink,
      source: {:erlang, :monitor},
      locations: [:getting_unlinked],
      expression: :monitored_child_exit,
      alternatives: [:unlink_before_flush, :unlink_at_flush]
    }
  ]

  def rules, do: @rules

  def rule!(id),
    do: Enum.find(@rules, &(&1.id == id)) || raise("undeclared comparator rule: #{inspect(id)}")

  def generators, do: rule!(:o1).sources
  def clocks, do: rule!(:o3).sources
  def readers, do: rule!(:o2b).readers
  def database_statements, do: rule!(:o4).statements
  def derivations, do: rule!(:o2a_computations).sources

  def function_slots(module, function),
    do: Map.get(rule!(:o2a_computations).function_slots, {module, function}, %{})

  def rename, do: rule!(:o2).rename

  def scheduling(id, expression) do
    %{expression: ^expression, alternatives: alternatives} = rule!(id)
    alternatives
  end

  def compute(id, args) do
    {module, function, arity} = Map.fetch!(rule!(id), :compute)
    true = length(args) == arity
    apply(module, function, args)
  end

  def context_copy_slots, do: rule!(:context_copy).slots

  def declaration_slots do
    {module, function, 0} = rule!(:o2b).fields
    apply(module, function, [])
  end

  def typed_fields(AshOnetime.Store.Claim.Request),
    do: %{id: :uuid, operation_hash: :operation}

  def typed_fields(module) when module in [Withheld, Returned], do: %{id: :uuid}
  def typed_fields(_), do: %{}

  def uuid_attributes(resource) do
    for attribute <- Ash.Resource.Info.attributes(resource),
        attribute.type == Ash.Type.UUID,
        do: attribute.name
  end

  # Shared lifecycle boundaries give both sides the same phase even where one
  # side has no delivery work. Delivery-only origins remain bound by D at their
  # own positions; their phases do not rename unrelated common occurrences.
  def phase({_, :call, {AshOnetime.Delivery, :armed_call, _}}, _), do: :armed

  def phase({_, :call, {Ash, function, _}}, _)
      when function in [:create, :update, :destroy, :run_action], do: :armed

  def phase({_, :call, {module, :reserve, _}}, _)
      when module in [AshOnetime.Change, AshOnetime.GenericAction], do: :claimed

  def phase({_, :call, {AshOnetime.Admission, :dispatch_reservation, _}}, _), do: :claimed

  def phase({_, :call, {module, :produce, _}}, _)
      when module in [AshOnetime.Change, AshOnetime.GenericAction], do: :produce_window

  def phase({_, :call, {AshOnetime.ExternalRecovery, :safe_execute, _}}, _), do: :produce_window
  def phase({_, :return_from, {AshOnetime.ExternalRecovery, :safe_execute, 5}, _}, _), do: :sealed
  def phase({_, :call, {AshOnetime.Delivery.Envelope, :encrypt, _}}, _), do: :sealed
  def phase({_, :call, {AshOnetime.Change, :complete, _}}, _), do: :sealed
  def phase({_, :call, {AshOnetime.GenericAction, :run, _}}, _), do: :sealed
  def phase({_, :call, {AshOnetime.Test.ExitBoundary.Consumer, :after_action, _}}, _), do: :sealed
  def phase({_, :call, {AshOnetime.Admission, :complete, _}}, _), do: :sealed
  def phase({_, :return_from, {AshOnetime.Admission, :complete, 2}, _}, _), do: :done
  def phase({_, :call, {AshOnetime.Delivery, :open, _}}, _), do: :open

  def phase({_, tag, {AshOnetime, :deliver, 2}, _}, _)
      when tag in [:return_from, :exception_from], do: :post

  def phase({_, tag, {Ash, function, 2}, _}, _)
      when tag in [:return_from, :exception_from] and
             function in [:create, :update, :destroy, :run_action], do: :post

  def phase({_, tag, {AshOnetime.Test.ExitBoundary.Root, :invoke, 2}, _}, _)
      when tag in [:return_from, :exception_from], do: :post

  def phase(_, current), do: current

  def hook_phase({_, :return_from, mfa, _}, current, hooks, frames) do
    canonical = Map.get(frames, mfa)

    if canonical do
      Enum.find_value(hooks, current, fn {slot, hook} ->
        if Map.get(frames, AshOnetime.Test.ExitBoundary.Hooks.trace_mfa(hook)) == canonical do
          case slot do
            {:before_action, 0} -> :sealed
            {:around_action, 0} -> :post
            {:after_action, 1} -> :done
          end
        end
      end)
    else
      current
    end
  end

  def hook_phase(_, current, _hooks, _frames), do: current

  def frames do
    @generators ++
      @clock_frames ++
      [{Process, :get, 1}, {Process, :get, 2}] ++
      [
        {Postgrex, :query, 4},
        {Postgrex, :query!, 4},
        {Ecto.Adapters.SQL, :query, 4},
        {Ecto.Adapters.SQL, :query!, 4},
        {Ecto.Adapters.SQL, :log, :_},
        {DBConnection.LogEntry, :new, :_},
        {DBConnection.LogEntry, :log, :_},
        {DBConnection, :event, 2},
        {DBConnection, :past_event, 3},
        {DBConnection, :checkout, 3},
        {DBConnection, :meter, 1},
        {DBConnection, :log, :_},
        {DBConnection.Holder, :checkout, :_},
        {DBConnection.Holder, :checkin, :_},
        {Postgrex.Protocol, :handle_prepare, :_},
        {Postgrex.Protocol, :handle_execute, :_},
        {Splode, :filter_stacktrace, 2}
      ]
  end

  def operation(resource, action),
    do:
      compute(:o2a_operation, [%{domain: :operation, resource: inspect(resource), action: action}])

  def declarations(resource) do
    Map.new(readers(), fn {module, function, 1} = reader ->
      {reader, apply(module, function, [resource])}
    end)
  end

  def hook_slots(type),
    do: Map.fetch!(rule!(:o2c).slots, if(type == :action, do: :action, else: :crud))

  def subject_hook_index(_row, {_list, index}), do: index

  def installer(type),
    do: Map.fetch!(rule!(:o2c).installers, if(type == :action, do: :action, else: :crud))

  def trace(row) do
    prefix = if row.external?, do: :external, else: :local

    case row.branch do
      :interrupted ->
        [:cell, :entry, :arm, :context, :claim, :external, :erase, :error_return]

      :transaction ->
        [:entry, :refusal_return]

      :direct ->
        [:claim_refusal, :error_return]

      :producer_failure ->
        [:cell, :entry, :arm, :context, :claim, :produce_failure, :erase, :error_return]

      :replay ->
        [:cell, :entry, :arm, :context, :claim, :replay, :open_empty, :erase, :return]

      :unknown ->
        [
          :cell,
          :entry,
          :arm,
          :context,
          :claim,
          :external,
          :recovered,
          :open_empty,
          :erase,
          :return
        ]

      :recovered ->
        [:cell, :entry, :arm, :context, :claim, :recovered, :open_empty, :erase, :return]

      :finalize_replay ->
        [
          :cell,
          :entry,
          :arm,
          :context,
          :claim,
          prefix,
          :seal,
          :finalize_replay,
          :open_empty,
          :erase,
          :return
        ]

      :consumer_failure ->
        [:cell, :entry, :arm, :context, :claim, prefix, :seal, :reraise, :erase, :error_return]

      :failure ->
        if row.fault == :codec_decode,
          do: [:cell, :entry, :arm, :context, :claim, :failure, :erase, :error_return],
          else: [
            :cell,
            :entry,
            :arm,
            :context,
            :claim,
            prefix,
            :seal,
            :failure,
            :erase,
            :error_return
          ]

      _execute ->
        [:cell, :entry, :arm, :context, :claim, prefix, :seal, :complete, :open, :erase, :return]
    end
  end
end
