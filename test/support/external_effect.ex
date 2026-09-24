defmodule AshOnetime.Test.ExternalEffectSupport do
  @moduledoc false

  alias AshOnetime.Test.{ExternalPeer, Repo}

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

  def recover(operation_key, subject) do
    # A LYING :absent — the adversarial-absence worst case (ROADMAP H10). The peer's
    # authoritative recover would return the stored effect or a true :absent; this mode
    # returns :absent REGARDLESS of peer state, modeling an adapter that fails to prove
    # absence. The library trusts :absent as authoritative proof and re-executes, so a
    # peer that already recorded the effect gets a SECOND effect — the double-spend that is the
    # adapter's fault, not the library's. This is inherent to the design (ADR-0001: the
    # idempotency guarantee reduces to adapter honesty); the defense is the normative
    # requirement on the adapter, not a library-side guard.
    if mode() == :lying_absent do
      :absent
    else
      if match?({:pause_recover_probe, _observer, _reference}, mode()) do
        pause_recover_probe(operation_key, subject)
      else
        recover_with_disposition(operation_key, subject)
      end
    end
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

  # Reports whether the callback is executing inside the caller's open transaction:
  # evaluated in the caller's process against the dynamic repo Ash opened the action
  # transaction on, before any peer call. Also captures the caller's backend pid (from
  # inside the same checked-out connection) so the observer can read that backend's
  # pg_stat_activity state while the callback is paused.
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
