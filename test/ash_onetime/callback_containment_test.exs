defmodule AshOnetime.CallbackContainmentTest do
  use ExUnit.Case, async: false
  alias AshOnetime.{Admission, Canonical, Error, Token}
  alias AshOnetime.Canonical.Decoder
  alias AshOnetime.KeyCustody.{Conformance, Local}
  alias AshOnetime.Resource.Info, as: ResourceInfo
  alias AshOnetime.Test.ActionExamples.Resource
  alias AshOnetime.Test.{KeyCustodyHolder, KeyMaterial}

  defmodule Callback do
    @moduledoc false
    def algorithms, do: [:hmac_sha256, :ed25519]
    def sign(_, _, _, context), do: run(context)
    def verify(_, _, _, _, context), do: run(context)
    def verify(_, _), do: run(:persistent_term.get(__MODULE__))
    def mint(_), do: run(:persistent_term.get(__MODULE__))

    defp run({owner, mode}) do
      send(owner, {:worker, self()})

      case mode do
        :raise ->
          raise "private custody diagnostic"

        :exit ->
          exit(:private_diagnostic)

        :kill ->
          receive do
            :finish -> :ok
          end

        :deadline ->
          receive do
            :finish -> :ok
          end

        :malformed ->
          {:ok, :wrong}

        {:return, result} ->
          result
      end
    end
  end

  defmodule TokenVerifier do
    @moduledoc false
    def verify(wire, _) do
      Token.verify(wire, Callback,
        algorithm: :hmac_sha256,
        namespace: "callbacks",
        max_age: 60,
        custody_context: :persistent_term.get(__MODULE__)
      )
    end
  end

  setup do
    old = Application.get_env(:ash_onetime, :callback_timeout_ms)
    Application.put_env(:ash_onetime, :callback_timeout_ms, 100)

    on_exit(fn ->
      if old,
        do: Application.put_env(:ash_onetime, :callback_timeout_ms, old),
        else: Application.delete_env(:ash_onetime, :callback_timeout_ms)

      :persistent_term.erase(Callback)
      :persistent_term.erase(TokenVerifier)
    end)

    {:ok, token} =
      Token.mint("nonce", algorithm: :hmac_sha256, key_id: "hmac", namespace: "callbacks")

    context = %{material: KeyMaterial, keys: Conformance.materials()}
    {:ok, wire} = Token.sign(token, Local, context)
    {:ok, token: token, wire: wire}
  end

  for kind <- [:custody_sign, :custody_verify, :verifier, :minter],
      mode <- [:raise, :exit, :kill, :deadline, :malformed],
      trap <- [false, true] do
    @tag callback_mode: mode
    test "#{kind} contains #{mode} with trap_exit #{trap}", %{token: token, wire: wire} do
      kind = unquote(kind)
      mode = unquote(mode)
      owner = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, unquote(trap))
          result = invoke(kind, token, wire, {owner, mode})
          send(owner, {:result, self(), result})

          receive do
            :inspect_mailbox -> send(owner, {:mailbox, self(), Process.info(self(), :messages)})
          end
        end)

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      assert_receive {:worker, worker}, 2_000
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      worker_monitor = Process.monitor(worker)
      kill_worker(mode, worker)
      expected = expected_code(kind, mode)
      assert_receive {:result, ^pid, {:error, %Error{code: ^expected, details: %{}}}}, 2_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 2_000
      refute Process.alive?(worker)
      send(pid, :inspect_mailbox)
      assert_receive {:mailbox, ^pid, {:messages, []}}
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    end
  end

  test "callback deadlines default to 5000 ms, are configurable and have a 30000 ms ceiling" do
    Application.delete_env(:ash_onetime, :callback_timeout_ms)
    assert AshOnetime.Callback.timeout() == 5_000
    Application.put_env(:ash_onetime, :callback_timeout_ms, 75)
    assert AshOnetime.Callback.timeout() == 75
    assert AshOnetime.Callback.timeout(90) == 90
    assert AshOnetime.Callback.timeout(30_001) == 30_000

    for invalid <- [:infinity, 0, -1, "secret"] do
      assert AshOnetime.Callback.timeout(invalid) == 5_000
    end

    protection = ResourceInfo.protection(Resource, :consume)
    refute Keyword.has_key?(protection.limits, :verifier_timeout_ms)
  end

  test "custody closed errors and exact ok are normalized without diagnostics", %{
    token: token,
    wire: wire
  } do
    for {returned, code} <- [
          {{:error, :key_unusable}, :key_unusable},
          {{:error, :unavailable}, :custody_unavailable},
          {{:error, :timeout}, :custody_timeout},
          {{:error, "secret"}, :custody_contract_violation},
          {{:error, Error.new(:invalid_signature, "secret", %{secret: "secret"})},
           :custody_contract_violation},
          {{:ok, true}, :custody_contract_violation},
          {true, :custody_contract_violation}
        ] do
      assert {:error, %Error{code: ^code, details: details, message: message}} =
               invoke(:custody_verify, token, wire, {self(), {:return, returned}})

      assert details == %{}
      refute message =~ "secret"
      assert_receive {:worker, _}
    end

    assert {:error, %Error{code: :invalid_signature}} =
             invoke(
               :custody_verify,
               token,
               wire,
               {self(), {:return, {:error, :invalid_signature}}}
             )

    assert_receive {:worker, _}

    assert {:error, %Error{code: :custody_contract_violation}} =
             invoke(:custody_sign, token, wire, {self(), {:return, {:error, :invalid_signature}}})

    assert_receive {:worker, _}
  end

  test "signature lengths are exact on both paths before custody verification", %{token: token} do
    holder = start_supervised!({KeyCustodyHolder, Conformance.materials()})

    for {algorithm, id, size} <- [{:hmac_sha256, "hmac", 32}, {:ed25519, "ed", 64}] do
      token = %{token | algorithm: algorithm, key_id: id}
      {:ok, wire} = Token.sign(token, KeyCustodyHolder, holder)
      "ash_onetime." <> encoded = wire

      {:ok, envelope} =
        encoded |> Base.url_decode64!(padding: false) |> Decoder.decode()

      for length <- [size - 1, size + 1] do
        {:ok, raw} = Canonical.encode(%{envelope | "signature" => :binary.copy(<<0>>, length)})
        calls = KeyCustodyHolder.calls(holder)

        assert {:error, %Error{code: :invalid_signature}} =
                 Token.verify(
                   "ash_onetime." <> Base.url_encode64(raw, padding: false),
                   KeyCustodyHolder,
                   algorithm: algorithm,
                   namespace: "callbacks",
                   max_age: 60,
                   custody_context: holder
                 )

        assert KeyCustodyHolder.calls(holder) == calls

        assert {:error, %Error{code: :custody_contract_violation}} =
                 invoke(
                   :custody_sign,
                   token,
                   wire,
                   {self(), {:return, {:ok, :binary.copy(<<0>>, length)}}}
                 )

        assert_receive {:worker, _}
      end
    end
  end

  test "verifiers and minters preserve only allowlisted codes with fixed messages", %{
    token: token,
    wire: wire
  } do
    for kind <- [:verifier, :minter],
        code <- [
          :invalid_signature,
          :key_unusable,
          :custody_unavailable,
          :custody_timeout,
          :outside_window,
          :algorithm_mismatch,
          :namespace_mismatch
        ] do
      returned = {:error, Error.new(code, "private diagnostic", %{secret: "private"})}

      assert {:error, %Error{code: ^code, message: message, details: details}} =
               invoke(kind, token, wire, {self(), {:return, returned}})

      assert details == %{}
      refute message =~ "private"
      assert_receive {:worker, _}
    end

    for kind <- [:verifier, :minter],
        returned <- [{:error, :refused}, {:error, Error.new(:store_failure, "private")}] do
      assert {:error, %Error{code: :verification_failed}} =
               invoke(kind, token, wire, {self(), {:return, returned}})

      assert_receive {:worker, _}
    end
  end

  test "a verifier wrapping Token.verify preserves custody unavailability", %{wire: wire} do
    :persistent_term.put(TokenVerifier, {self(), {:return, {:error, :unavailable}}})

    assert {:error, %Error{code: :custody_unavailable, details: %{}}} =
             prepare({:verified, :proof, TokenVerifier}, wire)

    assert_receive {:worker, _}
  end

  defp expected_code(kind, :deadline) when kind in [:custody_sign, :custody_verify],
    do: :custody_timeout

  defp expected_code(kind, _) when kind in [:custody_sign, :custody_verify],
    do: :custody_contract_violation

  defp expected_code(_, :deadline), do: :verification_timeout
  defp expected_code(_, _), do: :verifier_contract_violation

  defp kill_worker(:kill, worker), do: Process.exit(worker, :kill)
  defp kill_worker(_, _), do: :ok

  defp invoke(:custody_sign, token, _, context), do: Token.sign(token, Callback, context)

  defp invoke(:custody_verify, token, wire, context),
    do:
      Token.verify(wire, Callback,
        algorithm: token.algorithm,
        namespace: token.namespace,
        max_age: 60,
        custody_context: context
      )

  defp invoke(kind, _, wire, context) do
    :persistent_term.put(Callback, context)
    source = if kind == :verifier, do: {:verified, :proof, Callback}, else: {:minted, Callback}
    prepare(source, wire)
  end

  defp prepare(source, wire) do
    subject =
      Ash.ActionInput.for_action(Resource, :consume, %{proof: wire, value: 1},
        tenant: "callbacks"
      )

    protection = ResourceInfo.protection(Resource, :consume)

    Admission.prepare(
      subject,
      %{protection | key: [source], limits: [verifier_timeout_ms: 100]},
      %{}
    )
  end
end
