# ADR 0006: Point-event observability

Library telemetry emits point events, never span start/stop/exception triples.
The twelve admission/business events carry only strategy, resource, action, and result_class
atoms; the diagnosis event carries strategy, phase, and exception module atoms.
Measurements contain only count or duration. Keys, scopes, tokens, payloads, signatures,
exception values, and stacktraces must never enter metadata.

`Telemetry.attach/0` routes the full event surface to downstream metric events with unchanged
validated metadata. Consumers supply aggregation and tracing at their own call boundary.
Library spans cannot preserve this contract because span metadata adds context and exception values.
See [Telemetry](../../documentation/telemetry.md) for event names and classes.
