# Telemetry

`ash_onetime` emits a closed, value-free telemetry surface for keyed-effect admission. Every
event carries **measurements** (`:duration` in native units, or `:count`) and a fixed
**metadata** shape `%{strategy:, resource:, action:, result_class:}` — never the request
payload, response value, key material, fingerprint, or token. This is an invariant, not a
convention: the telemetry module validates the shape before emission and the
`forbidden-telemetry` mutation fixture in `scripts/check_mutations.exs` pins it.

Do **not** attach handlers that expect data-bearing metadata — those fields are never
present, and a handler that indexes into them will silently get a `nil`. Attach by event
name and branch on `result_class` (an atom), which is always present.

## Events

All events are prefixed `[:ash_onetime, <event>]`. Each event's metadata includes the
`result_class` atom named below.

| Event | Measurements | `result_class` values |
| --- | --- | --- |
| `[:ash_onetime, :admission]` | `:duration` | `:admitted` `:rejected` `:failed` |
| `[:ash_onetime, :conflict]` | `:count` (always 1) | `:complete` `:processing` `:nonce_used` `:malformed` |
| `[:ash_onetime, :replay]` | `:duration` | `:returned` `:rejected` |
| `[:ash_onetime, :fingerprint_mismatch]` | `:count` (always 1) | `:rejected` |
| `[:ash_onetime, :verification]` | `:duration` | `:verified` `:rejected` `:timeout` |
| `[:ash_onetime, :encoding]` | `:duration` | `:stored` `:rejected` `:rollback` `:failed` |
| `[:ash_onetime, :cache]` | `:count` (always 1) | `:hit` `:miss` `:stale` `:corrupt` `:failure` `:timeout` `:stored` `:expired` `:oversized` `:disabled` |
| `[:ash_onetime, :cleanup]` | `:count` | `:claims_deleted` `:partitions_dropped` |
| `[:ash_onetime, :reap]` | `:count` | `:claims_reaped` |
| `[:ash_onetime, :external_recovery]` | `:duration` | `:processing_committed` `:execute_succeeded` `:recover_succeeded` `:absence_proven` `:outcome_unknown` `:external_effect_unavailable` `:finalize_locked` `:replayed` |
| `[:ash_onetime, :store_uncertainty]` | `:count` (always 1) | `:sent` `:unknown` `:disconnected` `:lock_timeout` |
| `[:ash_onetime, :untracked_execution]` | `:count` (always 1) | `:checkout_unavailable` |

`strategy` is `:idempotency` or `:one_time_nonce`; `resource` and `action` are the module and
action atom the protection is declared on.

## A runnable handler

This handler counts admissions by result class per resource/action, and records admission
durations into a histogram. Attach it in your application startup (e.g. your app's
`start/2`), once per VM.

```elixir
defmodule MyApp.AshOnetimeMetrics do
  @doc """
  Attaches the admission metrics handler. Idempotent — safe to call once at boot.
  """
  def attach do
    :telemetry.attach_many(
      "my-app.ash-onetime.admission",
      [[:ash_onetime, :admission]],
      &__MODULE__.handle_admission/4,
      nil
    )
  end

  def handle_admission(_event, measurements, metadata, _config) do
    # metadata is always %{strategy:, resource:, action:, result_class:} — branch on the atom.
    labels = {metadata.resource, metadata.action, metadata.result_class}

    :telemetry.execute([:my_app, :ash_onetime, :admission_count], %{count: 1}, labels)

    # :duration is present on :admission events. Guard anyway — other events use :count.
    if duration = measurements[:duration] do
      :telemetry.execute([:my_app, :ash_onetime, :admission_duration], %{duration: duration}, labels)
    end
  end
end
```

Route these onward into your metrics backend (e.g. `:telemetry_metrics` statsd/prometheus
reporters) by attaching `Telemetry.Metrics` definitions in your release or `MyAppWeb.Telemetry`:

```elixir
summary("my_app.ash_onetime.admission_duration.duration",
  tag: [:resource, :action, :result_class],
  unit: {:native, :millisecond}
)

counter("my_app.ash_onetime.admission_count.total",
  tag: [:resource, :action, :result_class]
)
```

## What to alert on

- `[:ash_onetime, :admission]` with `result_class: :failed` rising — admission store errors
  (non-application failures). For idempotency these fail closed; for nonces they always fail
  closed. A spike means the store, not the client.
- `[:ash_onetime, :store_uncertainty]` — sent/unknown/disconnected/lock_timeout outcomes. These
  are the authoritative-state-unavailable conditions; for idempotency they may be the optional
  `:execute_untracked` path (`untracked_execution` follows), for nonces they fail closed.
- `[:ash_onetime, :external_recovery]` with `result_class: :outcome_unknown` — an external
  effect whose result could not be settled. These are the conservative ambiguous-outcome
  cases; see [External effects and recovery](external-effects.md).
- `[:ash_onetime, :untracked_execution]` — an idempotent action executed without a stored
  admission after a checkout failure. It is correct by design but worth visibility.

Events are deliberately low-cardinality: `resource`/`action`/`result_class` are atoms, so a
high-cardinality label (a key value, a payload hash) can never leak through this surface.
