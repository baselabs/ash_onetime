defmodule AshOnetime.Delivery.PrivateKeyTest do
  # Key custody (decision 5): the X25519 private key `deliver/2` generates never leaves
  # its process. The subject's context carries only `%{ref: ref}`. Every X25519 private key
  # generated during the call (deliver/2's own and the envelope's ephemeral one) is
  # recovered from a return trace of `:crypto.generate_key/2`, and none of them may
  # appear in anything that crosses to another process or to shared state: a message
  # (to a process or a port, which covers the database connection), a spawn's
  # arguments, an ETS write or a `:persistent_term` write. After the call, no process's
  # dictionary or mailbox holds one. The tracer is the observer: it alone receives the
  # trace of the return value.
  use AshOnetime.Test.StoreCase, async: false

  import AshOnetime.Test.DeliveryCase

  alias AshOnetime.Delivery

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  setup %{prefix: prefix} do
    install!(prefix)
  end

  for route <- [:create, :update, :destroy, :soft_destroy, :generic] do
    @route route

    @tag executing_only_private_key: true
    test "no other process ever holds the private key on #{route}", %{prefix: prefix} do
      subject = builder(prefix, @route, unique_key("private-key-#{@route}")).()

      {result, observed} =
        observe(fn ->
          subject
          |> hook(:before_transaction, &assert_reference_only/1, [])
          |> AshOnetime.deliver()
        end)

      assert %Delivery{outcome: :executed} = elem(result, tuple_size(result) - 1)

      # deliver/2's key and the envelope's ephemeral key.
      assert length(observed.secrets) >= 2
      assert observed.crossings != []
      assert leaks(observed) == []
      assert held_elsewhere(observed.secrets) == []
    end
  end

  @tag executing_only_private_key: true
  test "the control: a private key sent to another process is found", %{prefix: prefix} do
    subject = builder(prefix, :create, unique_key("private-key-control")).()
    receiver = spawn(fn -> receive(do: (:stop -> :ok)) end)

    {_result, observed} =
      observe(fn ->
        {_public, secret} = :crypto.generate_key(:ecdh, :x25519)
        send(receiver, {:leak, secret})
        AshOnetime.deliver(subject)
      end)

    assert [{:send, ^receiver}] = leaks(observed)
    send(receiver, :stop)
  end

  # Inside Ash's frame the subject carries the reference and nothing else under the
  # delivery key, and the entry holds the public key only.
  defp assert_reference_only(subject) do
    assert %{ref: ref} = reference = subject.context.private.ash_onetime_delivery
    assert map_size(reference) == 1
    assert byte_size(ref) == 16
    assert {:armed, pid, _resource, _action, _cell, public} = Process.get(Delivery.key(ref))
    assert pid == self()
    assert byte_size(public) == 32
    subject
  end

  defp observe(fun) do
    test = self()
    tracer = spawn_link(fn -> collect(test, []) end)
    patterns = [{:crypto, :generate_key, 2}, {:ets, :_, :_}, {:persistent_term, :put, 2}]

    result =
      try do
        for {module, _function, _arity} = mfa <- patterns do
          Code.ensure_loaded!(module)
          :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
        end

        :erlang.trace(test, true, [:send, :procs, :call, :set_on_spawn, {:tracer, tracer}])
        fun.()
      after
        :erlang.trace(test, false, [:send, :procs, :call, :set_on_spawn])
        for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [:local])
      end

    ref = :erlang.trace_delivered(test)
    receive(do: ({:trace_delivered, ^test, ^ref} -> :ok))
    send(tracer, {:report, test})
    events = receive(do: ({:events, ^tracer, events} -> events))

    {result, classify(events)}
  end

  defp collect(test, events) do
    receive do
      {:report, ^test} -> send(test, {:events, self(), Enum.reverse(events)})
      event -> collect(test, [event | events])
    end
  end

  defp classify(events) do
    secrets =
      for {:trace, _pid, :return_from, {:crypto, :generate_key, 2}, {_public, secret}} <- events,
          byte_size(secret) == 32,
          do: secret

    crossings =
      Enum.flat_map(events, fn
        {:trace, _pid, :send, message, to} -> [{{:send, to}, message}]
        {:trace, _pid, :send_to_non_existing_process, message, to} -> [{{:send, to}, message}]
        {:trace, _pid, :spawn, child, mfa} -> [{{:spawn, child}, mfa}]
        {:trace, _pid, :spawned, parent, mfa} -> [{{:spawned, parent}, mfa}]
        {:trace, _pid, :call, {:ets, function, _arity} = mfa, args} -> ets(function, mfa, args)
        {:trace, _pid, :call, {:persistent_term, :put, 2} = mfa, args} -> [{mfa, args}]
        _other -> []
      end)

    %{secrets: secrets, crossings: crossings}
  end

  @ets_writes [
    :insert,
    :insert_new,
    :update_element,
    :update_counter,
    :give_away,
    :setopts,
    :new,
    :select_replace
  ]

  defp ets(function, mfa, args) when function in @ets_writes, do: [{mfa, args}]
  defp ets(_function, _mfa, _args), do: []

  defp leaks(%{secrets: secrets, crossings: crossings}) do
    for {where, term} <- crossings, contains_any?(term, secrets), uniq: true, do: where
  end

  defp held_elsewhere(secrets) do
    for pid <- Process.list(),
        pid != self(),
        info = Process.info(pid, [:dictionary, :messages]),
        info != nil,
        contains_any?(info, secrets),
        do: pid
  end

  defp contains_any?(term, secrets) do
    binary = :erlang.term_to_binary(term)
    Enum.any?(secrets, &(:binary.match(binary, &1) != :nomatch))
  end
end
