defmodule AshOnetime.Test.ExitBoundary.Search do
  @moduledoc false
  alias AshOnetime.Delivery.Envelope
  alias AshOnetime.Test.ExitBoundary.{Analysis, HostCall, Origins}

  @exits for n <- 1..24, do: String.to_atom("e#{n}")

  # Rule 3 searches actual exits, independently of rule 4's verdict. In particular,
  # a rejected permitted-trace event does not become an allowed plaintext placement.
  def hits(side) do
    indexed = Origins.build(side)
    needles = Analysis.needles(Map.values(side.values))
    owned = HostCall.indexes(indexed.events)

    for e <- indexed.events,
        e.class in @exits,
        not MapSet.member?(owned, e.index),
        not transfer?(e),
        not result_protocol?(e.event, side),
        Analysis.contains?(e.event, needles),
        uniq: true,
        do: {e.class, e.mfa, e.index}
  end

  defp transfer?(%{mfa: {:crypto, function, 7}, stack: stack})
       when function in [:crypto_one_time_aead, :aead_cipher_nif] do
    Enum.any?(stack, &(&1 in [{Envelope, :encrypt, 3}, {Envelope, :decrypt, 5}]))
  end

  defp transfer?(_e), do: false

  # The fixture publishes the caller's exact return after Root.invoke returns.
  # Its endpoint and complete payload are fixed by the observer's own bindings.
  defp result_protocol?({root, :send, message, observer}, side),
    do: result_message?(root, observer, message, side)

  defp result_protocol?({root, :call, {:erlang, :send, [observer, message]}}, side),
    do: result_message?(root, observer, message, side)

  defp result_protocol?(_event, _side), do: false

  defp result_message?(root, observer, message, side) do
    root == side.run.snapshot.root and observer == side.run.fixture.observer and
      message === {:result, root, side.run.result, :post_drain}
  end
end
