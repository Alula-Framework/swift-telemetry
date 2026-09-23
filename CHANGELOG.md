# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-23

The first release as a package of its own. It was extracted from Flight,
where it shipped in 0.34 as `FlightTelemetry`, so that a library can emit
without depending on a framework (DECISIONS.md, T1).

### Added

- **`TelemetryCore`**: typed events, spans, handlers, metric definitions
  and a bounded async stream. swift-service-context is its only dependency.
- **`TelemetryMacros`**: `@TelemetryEvent`, `@TelemetrySpan`,
  `@TelemetryFields` and `@TelemetryMeasurements`. It re-exports the core.
- **`TelemetryTesting`**: `TelemetryTest.capture`, `capture(prefix:)`,
  `captureSpans` and `expectNoEmission`, isolated between parallel tests.
- **Benchmarks** that measure the targets and enforce zero allocations.
- **A compile-refusal check**: a string measurement, a tag that isn't a
  tag, another event's field and a malformed name each fail to compile.

### Changed, from Flight 0.34's `FlightTelemetry`

- **Modules:** `FlightTelemetry` is now `TelemetryCore` plus
  `TelemetryMacros`, and `FlightTelemetryTesting` is now
  `TelemetryTesting`. The macros are a separate product, so a library that
  writes its events by hand needs no swift-syntax.
- **The runtime's own events:** `flight.telemetry.handler_failed` is now
  `telemetry.handler_failed`, and `flight.telemetry.cardinality_exceeded`
  is now `telemetry.cardinality_exceeded`.
- **The service-context key:** it is now named `telemetry.span`, not
  `flight.telemetry.span`.
- **The stress-test variable:** it is now `TELEMETRY_STRESS_SECONDS`.
- **`Telemetry.stream`** moved here from Flight's bridges.
