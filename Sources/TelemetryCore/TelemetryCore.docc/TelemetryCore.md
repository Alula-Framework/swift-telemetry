# ``TelemetryCore``

Typed events and spans: libraries say what happened, applications decide
what it becomes.

## Overview

A library declares events and emits them. It never picks a backend and
never attaches a handler:

```swift
@TelemetryEvent("hangar.query")
public enum Query {
    public struct Measurements { public var duration: Duration; public var rows: Int }
    public struct Metadata { public var table: String }
}

Telemetry.emit(Query.self) { (.init(duration: elapsed, rows: rows.count), .init(table: "users")) }
```

An application attaches handlers, directly or through metric definitions
that a reporter turns into handlers. Until something is attached, an emit
is one atomic load and a branch: nothing is allocated, nothing is locked,
and the payload closure never runs.

Events are types, so the compiler holds the contract. A measurement must be
a number, a metric tag must be a ``TagValue`` of the event's own metadata,
and an event name must match the grammar. Each of these is checked at
build time.

This module depends on swift-service-context alone, and has no macros, so
no swift-syntax either. `TelemetryMacros` adds `@TelemetryEvent`,
`@TelemetrySpan` and `@TelemetryFields`, and re-exports this module.
`TelemetryTesting` captures events in tests. Reporting to a metrics,
tracing or logging backend belongs to whoever composes the application;
Alula's `AlulaTelemetryBridges` is one such composer. The package README
is the guide.

## Topics

### Declaring events

- ``TelemetryEvent``
- ``TelemetryFields``
- ``EventName``
- ``NoFields``

### Field values

- ``TelemetryMeasurement``
- ``TelemetryValue``
- ``TagValue``
- ``MeasurementValue``
- ``TelemetryPrimitive``
- ``FieldEncoder``

### Emitting

- ``Telemetry``

### Spans

- ``SpanEvent``
- ``SpanHandle``
- ``TelemetrySpanKind``
- ``SpanStartMeasurements``
- ``SpanDurationMeasurements``
- ``TelemetrySpanID``
- ``TelemetrySpanContext``
- ``SpanFlags``
- ``SpanPhase``
- ``HandlerSlot``

### Handlers

- ``TelemetryHandler``
- ``HandlerID``
- ``HandlerToken``
- ``HandlerTokens``
- ``AttachError``
- ``EventContext``
- ``AnyEvent``
- ``EventRecord``
- ``AnyEventRecord``
- ``SpanObserver``
- ``SpanStart``
- ``SpanStop``
- ``SpanFailure``

### Metrics

- ``TelemetryMetric``
- ``TelemetryMetricsBuilder``
- ``MetricDescriptor``
- ``MetricKind``
- ``MetricUnit``
- ``MetricBuckets``
- ``MetricRecorder``

### The runtime's own events

- ``TelemetryHandlerFailed``
- ``TelemetryCardinalityExceeded``
