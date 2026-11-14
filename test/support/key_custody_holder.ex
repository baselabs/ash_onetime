defmodule AshOnetime.Test.KeyCustodyHolder do
  @moduledoc false
  use GenServer
  @behaviour AshOnetime.KeyCustody

  alias AshOnetime.Signer.{Ed25519, HMAC}

  def start_link(materials), do: GenServer.start_link(__MODULE__, materials)
  @impl true
  def algorithms, do: [:hmac_sha256, :ed25519]

  @impl true
  def sign(algorithm, key_id, bytes, holder),
    do: GenServer.call(holder, {:sign, algorithm, key_id, bytes})

  @impl true
  def verify(algorithm, key_id, bytes, signature, holder),
    do: GenServer.call(holder, {:verify, algorithm, key_id, bytes, signature})

  def calls(holder), do: GenServer.call(holder, :calls)

  @impl true
  def init(materials), do: {:ok, {materials, 0}}

  @impl true
  def handle_call(:calls, _from, {_, calls} = state), do: {:reply, calls, state}

  def handle_call(request, _from, {materials, calls}) do
    purpose = elem(request, 0)
    algorithm = elem(request, 1)
    key_id = elem(request, 2)

    result =
      case Map.fetch(materials, {purpose, key_id}) do
        {:ok, %{algorithm: ^algorithm} = material} -> crypt(request, material)
        _ -> {:error, :key_unusable}
      end

    {:reply, result, {materials, calls + 1}}
  end

  defp crypt({:sign, algorithm, _, bytes}, material),
    do: signer(algorithm).sign(bytes, material)

  defp crypt({:verify, algorithm, _, bytes, signature}, material) do
    case signer(algorithm).verify(bytes, signature, material) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_signature}
    end
  end

  defp signer(:hmac_sha256), do: HMAC
  defp signer(:ed25519), do: Ed25519
end
