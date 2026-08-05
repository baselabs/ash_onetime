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

      :unknown_after_execute ->
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
    disposition = if mode() == :recover_unknown, do: :unknown, else: :authoritative
    ExternalPeer.recover(subject.to_tenant, operation_key, disposition)
  end

  defp peer_result(%Ash.ActionInput{} = input),
    do: %{value: Ash.ActionInput.get_argument(input, :value)}

  defp peer_result(%Ash.Changeset{} = changeset),
    do: %{value: Ash.Changeset.get_attribute(changeset, :amount)}
end
