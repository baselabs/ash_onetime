defmodule AshOnetime.Test.ExternalEffectSupport do
  @moduledoc false

  alias AshOnetime.Test.{ExternalPeer, Repo}
  alias Ecto.Adapters.SQL

  @mode_key {__MODULE__, :mode}

  def put_mode(mode), do: Process.put(@mode_key, mode)
  def reset_mode, do: Process.delete(@mode_key)
  def mode, do: Process.get(@mode_key, :normal)

  def pause_local(operation_key) do
    case mode() do
      {:pause_local, observer, reference} ->
        send(observer, {:external_pause, reference, :local_finalize, operation_key, self()})
        receive do: ({:external_continue, ^reference} -> :ok)

      _mode ->
        :ok
    end
  end

  def execute(operation_key, subject) do
    prefix = subject.to_tenant

    case mode() do
      {:pause_before_execute, observer, reference} ->
        send(observer, {:external_pause, reference, :before_execute, operation_key, self()})
        receive do: ({:external_continue, ^reference} -> :ok)
        {:ok, ExternalPeer.execute(prefix, operation_key, peer_result(subject))}

      {:hold_execute, observer, reference} ->
        # Holds the peer's key-claim transaction OPEN after its inserts (rows
        # uncommitted, key row lock held) until released: a peer whose execute is
        # deterministically still in flight while another caller reaches the peer.
        hold = fn ->
          send(observer, {:external_pause, reference, :held_execute, operation_key, self()})
          receive do: ({:external_continue, ^reference} -> :ok)
        end

        {:ok, ExternalPeer.execute(prefix, operation_key, peer_result(subject), hold: hold)}

      {:pause_after_execute, observer, reference} ->
        result = ExternalPeer.execute(prefix, operation_key, peer_result(subject))
        send(observer, {:external_pause, reference, :after_execute, operation_key, self()})
        receive do: ({:external_continue, ^reference} -> :ok)
        {:ok, result}

      {:pause_execute_probe, observer, reference} ->
        pause_execute_probe(prefix, operation_key, subject, observer, reference)

      mode when mode in [:unknown_after_execute, :execute_unknown_recover_unknown] ->
        # Both modes run execute at the peer (evidence lands once) and return an
        # unknown outcome. :execute_unknown_recover_unknown additionally makes the
        # subsequent recover return :unknown, driving the settle_unknown_execute
        # -> ambiguous_recovery path-D arm of the double-execute firewall.
        _result = ExternalPeer.execute(prefix, operation_key, peer_result(subject))
        {:error, :outcome_unknown}

      mode when mode in [:raise_execute, :throw_execute, :exit_execute, :invalid_execute] ->
        fault(mode, prefix, operation_key, subject)

      _mode ->
        {:ok, ExternalPeer.execute(prefix, operation_key, peer_result(subject))}
    end
  end

  def recover(operation_key, subject), do: recover(mode(), operation_key, subject)

  defp recover({:pause_recover_unknown, observer, reference}, operation_key, subject) do
    result = ExternalPeer.recover(subject.to_tenant, operation_key, :unknown)
    send(observer, {:external_pause, reference, :recover_unknown, operation_key, self()})
    receive do: ({:external_continue, ^reference} -> :ok)
    result
  end

  defp recover(mode, operation_key, subject)
       when mode in [
              :raise_recover,
              :throw_recover,
              :invalid_recover,
              :recover_failed_query,
              :recover_nested_rollback
            ] do
    # Read the authoritative peer before failing on the action's connection.
    _ = ExternalPeer.recover(subject.to_tenant, operation_key)
    recover_failure(mode)
  end

  # This deliberately false adapter answer exercises the peer's keyed admission.
  defp recover(:lying_absent, _operation_key, _subject), do: :absent

  defp recover({:pause_recover_probe, _observer, _reference}, operation_key, subject),
    do: pause_recover_probe(operation_key, subject)

  defp recover(_mode, operation_key, subject),
    do: recover_with_disposition(operation_key, subject)

  defp recover_failure(:raise_recover), do: raise("test recover failure")
  defp recover_failure(:throw_recover), do: throw(:test_recover_failure)
  defp recover_failure(:invalid_recover), do: :invalid

  defp recover_failure(:recover_failed_query) do
    {:error, _} = SQL.query(Repo, "SELECT 1/0", [])
    raise "recover query failed"
  end

  defp recover_failure(:recover_nested_rollback) do
    {:error, :recover_rollback} = Repo.transaction(fn -> Repo.rollback(:recover_rollback) end)
    :unknown
  end

  # Reports whether recover/3 is executing inside the caller's open transaction — the
  # same direct in-process observation the execute probe makes — then proceeds with an
  # authoritative recovery.
  defp pause_recover_probe(operation_key, subject) do
    observer = elem(mode(), 1)
    reference = elem(mode(), 2)
    in_transaction = Repo.in_transaction?()

    send(
      observer,
      {:external_pause, reference, :recover_probe, operation_key, self(), in_transaction}
    )

    receive do: ({:external_continue, ^reference} -> :ok)
    ExternalPeer.recover(subject.to_tenant, operation_key, :authoritative)
  end

  defp recover_with_disposition(operation_key, subject) do
    disposition =
      cond do
        mode() == :recover_unknown -> :unknown
        mode() == :execute_unknown_recover_unknown -> :unknown
        mode() == :recover_divergent -> :divergent
        true -> :authoritative
      end

    ExternalPeer.recover(subject.to_tenant, operation_key, disposition)
  end

  # The fault modes model an adapter whose execute call itself fails BEFORE any peer
  # evidence lands — they fault immediately, with no peer call.
  defp fault(:raise_execute, _prefix, _operation_key, _subject), do: raise("test execute failure")
  defp fault(:throw_execute, _prefix, _operation_key, _subject), do: throw(:test_execute_failure)
  defp fault(:exit_execute, _prefix, _operation_key, _subject), do: exit(:test_execute_failure)
  defp fault(:invalid_execute, _prefix, _operation_key, _subject), do: :invalid

  # Observe the caller's open transaction from inside the callback before any peer call.
  # Capture the backend pid on the same checked-out dynamic-repo connection.
  # An observer can then inspect its transaction state while the callback is paused.
  defp pause_execute_probe(prefix, operation_key, subject, observer, reference) do
    in_transaction = Repo.in_transaction?()
    backend_pid = backend_pid!()

    send(
      observer,
      {:external_pause, reference, :execute_probe, operation_key, self(), in_transaction,
       backend_pid}
    )

    receive do: ({:external_continue, ^reference} -> :ok)
    {:ok, ExternalPeer.execute(prefix, operation_key, peer_result(subject))}
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp peer_result(%Ash.ActionInput{} = input),
    do: %{value: Ash.ActionInput.get_argument(input, :value)}

  defp peer_result(%Ash.Changeset{} = changeset),
    do: %{value: Ash.Changeset.get_attribute(changeset, :amount)}
end
