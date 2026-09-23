// Every shape README.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import ServiceContextModule
import TelemetryMacros
import TelemetryTesting

// snippet.hide
func run(_ sql: String) async throws -> [Int] { [] }
let sql = "select 1"
let elapsed = Duration.milliseconds(3)
let rows = [1, 2, 3]
let evicted = 2
@TelemetryEvent("pool.stats")
enum PoolStats {
    struct Measurements { var idle: Int }
}
struct SlowQueries: Sendable { func record(_ table: String) {} }
let slowQueries = SlowQueries()
struct Pager: Sendable { func notify(_ message: String) async {} }
let pager = Pager()
struct User {}
struct Repository { func all(_: User.Type) async throws -> [User] { [] } }
let repository = Repository()
struct MyObserver: SpanObserver {
    func start(_ span: borrowing SpanStart, context: inout ServiceContext) {}
    func stop(_ span: borrowing SpanStop, state: consuming ()) {}
    func exception(_ span: borrowing SpanFailure, state: consuming ()) {}
}
enum CacheEvents {
    @TelemetryEvent("cache.hit")
    enum Hit {}
    @TelemetryEvent("cache.store_failed")
    enum StoreFailed { struct Metadata { var operation: String } }
    @TelemetryEvent("cache.evicted")
    enum Evicted { struct Measurements { var entries: Int } }
}
// snippet.show

// MARK: Declaring an event

@TelemetryEvent("hangar.query")
public enum Query {
    public struct Measurements {
        public var duration: Duration
        public var rows: Int
    }
    public struct Metadata {
        public var table: String
        public var statement: String? = nil  // opt-in, high-cardinality
    }
}

// MARK: Emitting

func emitting() {
    Telemetry.emit(Query.self) {
        (.init(duration: elapsed, rows: rows.count), .init(table: "users"))
    }
    Telemetry.emit(CacheEvents.Hit.self)
    Telemetry.emit(CacheEvents.StoreFailed.self) { .init(operation: "save") }
    Telemetry.emit(CacheEvents.Evicted.self) { .init(entries: evicted) }
}

func emittingWithAClock() async throws {
    let start = Telemetry.isEnabled(Query.self) ? ContinuousClock.now : nil
    let rows = try await run(sql)
    Telemetry.emit(Query.self) {
        (.init(duration: start.map { .now - $0 } ?? .zero, rows: rows.count), .init(table: "users"))
    }
}

// MARK: Spans

@TelemetrySpan("hangar.query", kind: .client)
public enum QuerySpan {
    public struct Metadata { public var table: String }
    public struct StopMetadata { public var rows: Int = 0 }
}

func spans() async throws -> [Int] {
    let rows = try await Telemetry.span(QuerySpan.self, metadata: .init(table: "users")) { span in
        let rows = try await run(sql)
        span.stopMetadata.rows = rows.count
        return rows
    }
    return rows
}

// MARK: Metrics

let metrics: [TelemetryMetric] = [
    .counter(QuerySpan.Stop.self),
    .distribution(QuerySpan.Stop.self, \.duration, unit: .milliseconds, tags: \.table),
    .sum(Query.self, \.rows, tags: \.table),
    .lastValue(PoolStats.self, \.idle),
    .counter(QuerySpan.Exception.self, tags: \.errorType, keep: { $0.table != "audit" }),
]

final class Printer: MetricRecorder {
    let descriptor: MetricDescriptor
    init(_ descriptor: MetricDescriptor) { self.descriptor = descriptor }
    func record(_ value: MeasurementValue, tags: [String]) {
        print(descriptor.name, descriptor.number(value), tags)
    }
}

func reporting() throws {
    var tokens = HandlerTokens()
    for metric in metrics {
        tokens.append(try metric.attach(recording: Printer(metric.descriptor), id: "print:\(metric.descriptor.name)"))
    }
    _ = consume tokens
}

// MARK: Handlers

func handlers() throws {
    let token = try Telemetry.attach(QuerySpan.Stop.self, id: "slow-queries") { measurements, metadata, _ in
        if measurements.duration > .seconds(1) { slowQueries.record(metadata.table) }
    }
    let all = try Telemetry.attach(prefix: "hangar", id: "debug") { event in
        print(event.name)  // everything under hangar.*, whatever its type
    }
    let tracing = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", MyObserver())
    _ = consume token
    _ = consume all
    _ = consume tracing
}

func slowConsumers() async throws {
    let failures = try Telemetry.stream(CacheEvents.StoreFailed.self, id: "pager", capacity: 256)
    for await failure in failures.events {
        await pager.notify("cache store \(failure.metadata.operation) failed")
    }
}

// MARK: Testing

func testing() async throws {
    let stops = try await TelemetryTest.capture(QuerySpan.Stop.self) {
        _ = try await repository.all(User.self)
    }
    precondition(stops.map(\.metadata.table) == ["users"])
}
