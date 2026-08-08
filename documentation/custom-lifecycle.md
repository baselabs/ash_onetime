# Custom lifecycle callbacks on protected actions

A protected action replays a **stored response** on a repeat of the same key. That replay
skips re-executing the action's effects — but it still runs the action's lifecycle callbacks
(the `change`, `validate`, and `prepare` pipeline). For that to be safe, every custom
lifecycle callback on a protected action must **declare** whether it is safe to run again
during a replay, and what capabilities it claims. `ash_onetime` enforces this at **compile
time**: a custom callback that does not declare its replay safety fails the resource's
compilation with `must export replay_safety/1`.

This guide is for authors of custom `Ash.Resource.Change`, `Ash.Resource.Validation`, and
`Ash.Resource.Preparation` modules that will sit on a protected action. For the *caller-facing*
replay signal (how to tell fresh execution from a stored replay in your HTTP layer), see
[Replay](replay.md).

## When you need the callbacks

You need them when a protected action carries a **custom, module-based** lifecycle callback —
one you wrote rather than a built-in. Built-in callbacks are pre-classified as replay-safe and
need nothing:

| Built-in                                                          | Needs callbacks? |
|-------------------------------------------------------------------|------------------|
| `Ash.Resource.Change.{Atomic, AtomicSet, Filter, Increment, OptimisticLock, PreventChange, Select, SetAttribute, SetContext}` | no |
| `Ash.Resource.Preparation.{Build, SetContext}`                   | no |
| The built-in validations in the replay-safe set                   | no |
| **Any custom module** you write                                   | **yes**          |
| Inline `change fn ...` / `prepare fn ...` (Ash's function-backed change/preparation) | **rejected** — inline callbacks cannot declare replay safety; extract them to a module |

A custom callback declares its replay safety by implementing the
`AshOnetime.ReplaySafety` behaviour, which carries two callbacks:

```elixir
defmodule AshOnetime.ReplaySafety do
  @type mode :: :pure | :replay_aware
  @type capabilities :: %{
          notifications: boolean(),
          effects: boolean(),
          around_action: boolean(),
          marker: :unused | :consumed
        }
  @callback replay_safety(opts :: Keyword.t()) :: mode()
  @callback replay_capabilities(opts :: Keyword.t()) :: capabilities()
end
```

The transformer calls both at **compile time** (passing the callback's declared opts) and
validates the combination. A mismatched declaration is a compile error, not a runtime one.

## `:pure` vs `:replay_aware`

The mode you return from `replay_safety/1` states how your callback behaves under replay:

- **`:pure`** — the callback has **no observable effects** (no writes, no notifications, no
  external side effects). It only reads or transforms the changeset/subject in memory. Pure
  callbacks are safe to run any number of times, including during replay, because running them
  again changes nothing observable. This is the mode for read-only enrichments, defaults,
  in-memory computations, and validations that only inspect the changeset.

- **`:replay_aware`** — the callback **may** have effects (a write to an audit table, an
  emitted notification, an external call), AND its code **explicitly checks whether this run
  is a replay** and skips or adjusts the effect when it is. A replay-aware callback promises
  that it has handled replay itself — typically by branching on the changeset-level replay
  signal and suppressing the side effect on the replay path.

The `marker` field records that promise: `:pure` uses `:unused` (it never needs to check,
because it has nothing to suppress); `:replay_aware` uses `:consumed` (it has taken
responsibility for the replay decision).

## The capability map

`replay_capabilities/1` returns a four-key map declaring what your callback does:

| Key             | Type    | Meaning |
|-----------------|---------|---------|
| `notifications` | boolean | Emits Ash notifications / notifiers (e.g. `Ash.Notifier.Notification`). |
| `effects`       | boolean | Has side effects beyond notifications (DB writes outside the action's own transaction, external HTTP, process sends, etc.). |
| `around_action` | boolean | Wraps the action in an `around_action` (opens a new boundary around the whole action). **Must be `false`** — `ash_onetime` owns the sole around-action boundary. |
| `marker`        | `:unused` \| `:consumed` | Whether the callback takes responsibility for the replay decision. `:unused` for `:pure`; `:consumed` for `:replay_aware`. |

The validation the transformer applies:

| Mode            | Required capability map                                                    |
|-----------------|----------------------------------------------------------------------------|
| `:pure`         | `%{notifications: false, effects: false, around_action: false, marker: :unused}` |
| `:replay_aware` | `%{around_action: false, marker: :consumed}` (`notifications`/`effects` are free booleans — declare truthfully) |
| (either)        | `around_action: true` is **always rejected** ("declares an additional around-action boundary") |

The two booleans on a `:replay_aware` callback are for your truthful declaration — they do
not change replay handling, but they document what the callback does so the contract is
auditable. Declare them from your opts when the behavior is configurable (see the worked
example below).

## Worked example: a `:pure` change

A change that only sets a server-side default is pure — running it again during replay changes
nothing observable:

```elixir
defmodule MyApp.Changes.SetDefaultCurrency do
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.change_attribute(changeset, :currency, opts[:to])
  end

  @impl AshOnetime.ReplaySafety
  def replay_safety(_opts), do: :pure

  @impl AshOnetime.ReplaySafety
  def replay_capabilities(_opts) do
    %{notifications: false, effects: false, around_action: false, marker: :unused}
  end
end
```

Use it on the protected action like any change:

```elixir
actions do
  create :charge do
    change SetDefaultCurrency, to: :usd
    # ...your idempotency key argument, validation, etc.
  end
end
```

## Worked example: a `:replay_aware` change

A change that writes an audit row only on the **fresh** execution (not the replay) must check
the replay signal itself. This is the canonical `:replay_aware` shape — branch on the
changeset-level replay signal and suppress the effect on the replay path:

```elixir
defmodule MyApp.Changes.RecordChargeLedger do
  use Ash.Resource.Change
  alias AshOnetime.Admission

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn final_changeset, result ->
      # Skip the ledger write on a stored-response replay.
      unless Admission.replay?(final_changeset) do
        MyApp.Ledger.record_charge(result, opts[:ledger_key])
      end

      {:ok, result}
    end)
  end

  @impl AshOnetime.ReplaySafety
  def replay_safety(_opts), do: :replay_aware

  @impl AshOnetime.ReplaySafety
  def replay_capabilities(opts) do
    %{
      notifications: Keyword.get(opts, :notify?, false),
      effects: true,
      around_action: false,
      marker: :consumed
    }
  end
end
```

Two things to notice:

1. **The replay check is the author's responsibility.** `:replay_aware` is a *promise* that
   you handled replay. Returning `:replay_aware` while **not** branching on
   `Admission.replay?/1` compiles fine — but it silently runs the effect on the replay too,
   defeating idempotency. The compile-time check cannot read your runtime logic, so the
   `marker: :consumed` value is your signed declaration that you did the work. Declare it
   truthfully.
2. **Use `after_action`/`before_action`, not `around_action`.** `around_action: true` is
   always rejected because `ash_onetime` must own the sole around-action boundary on a
   protected action. Compose your effect as a before/after hook instead.

## Validations and preparations

Custom `Ash.Resource.Validation` and `Ash.Resource.Preparation` modules follow the same rule:
implement `AshOnetime.ReplaySafety` and return the mode + capability map. A validation that
only inspects the changeset is `:pure`; a preparation that emits a notification or writes is
`:replay_aware` and must branch on `Admission.replay?/1`.

## Nonce actions: a tighter rule

A `:one_time_nonce` action has no stored-response surface — it runs exactly once. Its
constraint is the **sole around-action boundary**: any non-builtin `change` on a nonce action
must export `replay_capabilities/1` and declare `around_action: false` (the mode/marker are
not checked here — only that the change does not open a second around-action boundary). If you
author a custom change for a nonce action, implement at least `replay_capabilities/1`
returning a four-key map with `around_action: false`.

## Debugging a compile error

| Compile error | Cause | Fix |
|---|---|---|
| `<module> must export replay_safety/1` | Custom change/prep/validation on an idempotent action missing the callback | Implement `replay_safety/1` returning `:pure` or `:replay_aware` |
| `<module> must export replay_capabilities/1` (idempotent) or `... to prove it adds no around-action boundary` (nonce) | Missing the capability map | Implement `replay_capabilities/1` returning the four-key map with `around_action: false` |
| `declares notification/effect capabilities incompatible with :pure` | Declared `:pure` but returned a map with `notifications: true` or `effects: true` | Either keep the map all-false for `:pure`, or switch to `:replay_aware` and branch on replay |
| `must consume the replay marker and declare closed capabilities` | Declared `:replay_aware` but `marker:` is not `:consumed` | Set `marker: :consumed` and ensure your code branches on `Admission.replay?/1` |
| `declares an additional around-action boundary` | `around_action: true` | Set `around_action: false`; use `before_action`/`after_action` instead of `around_action` |
| `inline lifecycle callbacks cannot declare replay safety` | Used `change fn ...` or `prepare fn ...` | Extract the function into a module that implements `AshOnetime.ReplaySafety` |
