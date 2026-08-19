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
| `[:ash_onetime, :cleanup]` | `:count` | `:claims_deleted` `:partitions_dropped` `:partitions_created` |
| `[:ash_onetime, :reap]` | `:count` | `:claims_reaped` |
| `[:ash_onetime, :external_recovery]` | `:duration` | `:processing_committed` `:execute_succeeded` `:recover_succeeded` `:absence_proven` `:outcome_unknown` `:external_effect_unavailable` `:finalize_locked` `:replayed` |
| `[:ash_onetime, :store_uncertainty]` | `:count` (always 1) | `:sent` `:unknown` `:disconnected` `:lock_timeout` `:worker_timeout` |
| `[:ash_onetime, :untracked_execution]` | `:count` (always 1) | `:checkout_unavailable` |

`[:ash_onetime, :uncertain_exception]` is a store-internal diagnosis event (NOT admission-
shaped — it has no `result_class`). Emitted when a committed-claim transaction raises before
collapsing to `:dispatched_unknown`. Measurements `%{count: 1}`; metadata `%{strategy:,
phase:, exception:}` where `exception` is the exception struct MODULE (e.g. `Postgrex.Error`)
— the class only, not the struct, to avoid leaking request material. It bypasses the
admission `emit/6` validator (which requires `resource`/`action`/`result_class`) and calls
`:telemetry.execute/3` directly. A fresh application sees nothing unless it attaches a handler.

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

## Out-of-the-box attach helper

If you want the full closed event surface routed into a single downstream stream without
hand-rolling the event list and the count/duration split, the library ships an opt-in
helper:

```elixir
# in your application startup, once per VM, after the repo is started
AshOnetime.Telemetry.attach()
```

`attach/0` attaches a handler to every `[:ash_onetime, *]` event — all 13, no silent drops:
the 12 admission/business events and the `:uncertain_exception` diagnosis event (its
`%{strategy, phase, exception}` metadata forwards unchanged, normalized to `count: 1`, so
the diagnosis stream rides the same single attach point). Each event is re-emitted as a
downstream `[:ash_onetime, event, :metric]` event carrying the same atoms-only metadata and a
normalized `:count` or `:duration` measurement. Attach your own aggregator
(`Telemetry.Metrics` reporter, a custom handler, an ETS counter) to the `:metric` events:

```elixir
:telemetry.attach_many(
  "my-app.ash-onetime.metrics",
  [
    [:ash_onetime, :admission, :metric],
    [:ash_onetime, :store_uncertainty, :metric],
    [:ash_onetime, :uncertain_exception, :metric],
    # ...or the full [:ash_onetime, event, :metric] list
  ],
  &MyApp.Metrics.handle/4,
  nil
)
```

The handler is a pure router — no state, no new metadata, no dependency on `telemetry_metrics`
— so the value-free guarantee is preserved. `attach/1` accepts a `:name` to attach alongside
another consumer; `detach/1` undoes it. If you already maintain a `Telemetry.Metrics` reporter
centrally, declare the counter/summary definitions in your own `MyApp.Telemetry` against the
original events (the example above) rather than using `attach/0` — both paths are supported.

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

## Span-style events (start/stop)

`ash_onetime` emits **point events**, not span events. There is no
`*.start` / `*.stop` / `*.exception` triple on any event family: every event is a single
`:telemetry.execute/3` carrying `:duration` (latency-bearing events) or `:count` (count
events) plus the fixed atoms-only metadata described above. This is a deliberate invariant,
not a gap to close.

### Why no spans

The value-free metadata guarantee — the four atoms `strategy` / `resource` / `action` /
`result_class`, and nothing else — is enforced by the telemetry module's validator and
pinned by the `forbidden-telemetry` mutation fixture in `scripts/check_mutations.exs`.
`:telemetry.span/3` cannot satisfy it:

1. **`span/3` force-injects `telemetry_span_context` onto every event's metadata**
   unconditionally (`deps/telemetry/src/telemetry.erl:446-448`). The closed four-atom
   metadata shape would gain a fifth key on every span event by construction.
2. **`span/3` emits `:exception` with `kind` / `reason` / `stacktrace` merged onto the
   metadata, *inside* the span, before any caller `rescue` can catch it**
   (`telemetry.erl:378-387`). The span's `catch` fires the `:exception` event and then
   re-raises; the admission entry points' `rescue`/`catch` coerce the re-raise to a typed
   `:failed` result, but the event has already been dispatched. An exception `reason` or
   `stacktrace` can carry secret-bearing terms (an `AshOnetime.Error` struct, a
   `Postgrex.Error` with query text, a typed-argument mismatch carrying a token), and the
   surface exists precisely to keep such terms out of telemetry.

For the latency-bearing event families (`:admission`, `:replay`, `:verification`,
`:encoding`, `:external_recovery`), `:duration` is already on the point event — p99/SLO
measurement does not require spans.

### Trace correlation: wrap at the consumer boundary

If you need start/stop pairing for distributed-trace correlation (stitching an admission
into a cross-service trace), apply `:telemetry.span/3` at **your** call site, where you own
both the metadata and the exception handling:

```elixir
def MyApp.create_safely(input) do
  {result, _} =
    :telemetry.span(
      [:my_app, :ash_onetime, :admission],
      %{strategy: :idempotency, resource: MyResource, action: :create},
      fn ->
        case Ash.create(MyResource, input) do
          {:ok, record} -> {{:ok, record}, %{result_class: :admitted}}
          {:error, error} -> {{:error, error}, %{result_class: :rejected}}
        end
      end
    )

  result
end
```

You control the `start`/`stop`/`exception` metadata at that boundary, so any values you
emit are your decision, not the library's. The library's point events remain the
authoritative, value-free record of the classified outcome.
