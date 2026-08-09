defmodule AshOnetime.Test.ExternalEffectSupport do
  @moduledoc false

  alias AshOnetime.Test.ExternalPeer

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

      {:pause_after_execute, observer, reference} ->
        result = ExternalPeer.execute(prefix, operation_key, peer_result(subject))
        send(observer, {:external_pause, reference, :after_execute, operation_key, self()})
        receive do: ({:external_continue, ^reference} -> :ok)
        {:ok, result}

      mode when mode in [:unknown_after_execute, :execute_unknown_recover_unknown] ->
        # Both modes run execute at the peer (evidence lands once) and return an
        # unknown outcome. :execute_unknown_recover_unknown additionally makes the
        # subsequent recover return :unknown, driving the settle_unknown_execute
        # -> ambiguous_recovery path-D arm of the double-execute firewall.
        _result = ExternalPeer.execute(prefix, operation_key, peer_result(subject))
        {:error, :outcome_unknown}

      :raise_execute ->
        raise "test execute failure"

      :throw_execute ->
        throw(:test_execute_failure)

      :exit_execute ->
        exit(:test_execute_failure)

      :invalid_execute ->
        :invalid

      _mode ->
        {:ok, ExternalPeer.execute(prefix, operation_key, peer_result(subject))}
    end
  end

  def recover(operation_key, subject) do
    # A LYING :absent — the adversarial-absence worst case (ROADMAP H10). The peer's
    # authoritative recover would return the stored effect or a true :absent; this mode
    # returns :absent REGARDLESS of peer state, modeling an adapter that fails to prove
    # absence. The library trusts :absent as authoritative proof and re-executes, so a peer
    # that already recorded the effect gets a SECOND effect — the double-spend that is the
    # adapter's fault, not the library's. This is inherent to the design (ADR-0001: the
    # idempotency guarantee reduces to adapter honesty); the defense is the normative
    # requirement on the adapter, not a library-side guard.
    if mode() == :lying_absent do
      :absent
    else
      disposition =
        cond do
          mode() == :recover_unknown -> :unknown
          mode() == :execute_unknown_recover_unknown -> :unknown
          mode() == :recover_divergent -> :divergent
          true -> :authoritative
        end

      ExternalPeer.recover(subject.to_tenant, operation_key, disposition)
    end
  end

  defp peer_result(%Ash.ActionInput{} = input),
    do: %{value: Ash.ActionInput.get_argument(input, :value)}

  defp peer_result(%Ash.Changeset{} = changeset),
    do: %{value: Ash.Changeset.get_attribute(changeset, :amount)}
end
