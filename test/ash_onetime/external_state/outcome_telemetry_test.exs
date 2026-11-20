defmodule AshOnetime.ExternalState.OutcomeTelemetryTest do
  use ExUnit.Case, async: false
  alias AshOnetime.Telemetry

  test "an unrecorded outcome emits the external recovery diagnostic" do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ash_onetime, :external_recovery],
        fn event, measurements, metadata, _ ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Telemetry.external_recovery(
               1,
               :idempotency,
               AshOnetime.Test.ActionExamples.Resource,
               :external_generic,
               :outcome_unrecorded
             )

    assert_receive {[:ash_onetime, :external_recovery], %{duration: 1},
                    %{result_class: :outcome_unrecorded}}
  end
end
