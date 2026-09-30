# swift-telemetry

Libraries say what happened. Applications decide what it becomes.

A library emits typed **events**: a session was created, a query finished,
a push was refused. It never picks a metrics backend or a log format, and
it never attaches anything. The application attaches **handlers**, and a
handler can turn an event into a counter, a histogram, a tracing span, a
log line, or an assertion in a test. Until something is attached, an emit
is one atomic load and a branch.

Telemetry is **observational only**. Removing every handler must not
change what the application does. It reports facts that already happened
and never commands anything; see [The laws](#the-laws).

This is Elixir's `:telemetry`, typed. Events are Swift types, so a
measurement that isn't a number, a metric tag that isn't a tag, or a tag
taken from another event's fields fails to compile.

```swift
.package(url: "https://github.com/Alula-Framework/swift-telemetry.git", from: "0.1.0"),

.product(name: "TelemetryCore", package: "swift-telemetry")     // emit and attach; swift-service-context only
.product(name: "TelemetryMacros", package: "swift-telemetry")   // @TelemetryEvent, @TelemetrySpan; re-exports the core
.product(name: "TelemetryTesting", package: "swift-telemetry")  // capture in tests
```

A library depends on `TelemetryCore`, or on `TelemetryMacros` to use the
macros, and on nothing else: no framework, and no backend. Every
conformance the macros write can be written by hand, so a library that
wants no swift-syntax in its build can have that. Requires Swift 6.3 and
macOS 15, or Linux.

**Reporting belongs to the application.** Turning events into
swift-metrics metrics, swift-distributed-tracing spans or swift-log lines
is the job of whoever composes the application. [Alula](https://github.com/Alula-Framework/alula)'s
`AlulaTelemetryBridges` is one such composer, with a swift-metrics
reporter, a tracing observer and a log bridge. Anything else can attach
handlers the same way (see [Reporting](#reporting)).

## Declaring an event

An event is a caseless enum, named for what happened. The examples here
use a database library's query event, `hangar.query`; it illustrates the
shape, and Hangar itself emits no telemetry today.

```swift
@TelemetryEvent("hangar.query")
public enum Query {
    public struct Measurements {
        public var duration: Duration
        public var rows: Int
    }
    public struct Metadata {
        public var table: String
        public var statement: String? = nil   // opt-in, high-cardinality
    }
}
```

- **Measurements** are what metrics aggregate: integers, `Double`,
  `Duration`. A string measurement is a compile error at the property.
- **Metadata** is what they're sliced by. It holds any
  `TelemetryValue`: strings, `Bool`, numbers, `UUID`, optionals, and enums
  backed by a `String` or `Int`. An optional that's `nil` is left out
  entirely.
- **Either may be left out.** It's `NoFields` then. `@TelemetryEvent("app.sessions.created") public enum Created {}`
  is a whole event.
- **Names** are dot-separated lowercase segments, `[a-z][a-z0-9_]*`, and
  are checked at build time. **Field names** are the property names,
  snake_cased: `errorType` is `error_type`, `requestURL` is `request_url`.
- **A public struct gets a public memberwise initializer**, because Swift
  synthesizes one only as `internal`.

Put a library's events in a public namespace (`CacheEvents.Hit`,
`Hangar.Events.Query`) and document them. They're API, and follow semver
like any other. `@TelemetryFields` (metadata) and `@TelemetryMeasurements`
make a struct shared by several events encode itself. Every piece the
macros write can be written by hand; `Tests/Telemetry` has examples.

## Emitting

```swift
Telemetry.emit(Query.self) {
    (.init(duration: elapsed, rows: rows.count), .init(table: "users"))
}
Telemetry.emit(CacheEvents.Hit.self)                                   // nothing to carry
Telemetry.emit(CacheEvents.StoreFailed.self) { .init(operation: "save") }  // metadata only
Telemetry.emit(CacheEvents.Evicted.self) { .init(entries: evicted) }       // measurements only
```

The closure runs only if something will see the event. With nothing
attached there is no allocation, no lock and no task-local read, and the
payload is never built.

For a measurement taken *before* the emit point, typically a start time,
ask first so an unobserved operation doesn't read the clock either:

```swift
let start = Telemetry.isEnabled(Query.self) ? ContinuousClock.now : nil
let rows = try await run(sql)
Telemetry.emit(Query.self) {
    (.init(duration: start.map { .now - $0 } ?? .zero, rows: rows.count), .init(table: "users"))
}
```

## Spans

An operation with a duration is a span: it starts, then either stops or
throws.

```swift
@TelemetrySpan("hangar.query", kind: .client)
public enum QuerySpan {
    public struct Metadata { public var table: String }
    public struct StopMetadata { public var rows: Int = 0 }
}

let rows = try await Telemetry.span(QuerySpan.self, metadata: .init(table: "users")) { span in
    let rows = try await run(sql)
    span.stopMetadata.rows = rows.count
    return rows
}
```

The macro writes three phase events, and each is an ordinary event with
its own handlers:

| Phase | Measurements | Metadata |
|---|---|---|
| `QuerySpan.Start` (`hangar.query.start`) | `monotonicTime` | `table` |
| `QuerySpan.Stop` (`hangar.query.stop`) | `duration` | `table`, `rows` |
| `QuerySpan.Exception` (`hangar.query.exception`) | `duration` | `table`, `errorType`, `rows` |

`StopMetadata` is optional. It's what the body learns as it runs, and
every field needs a default, because a span that throws early reports the
defaults. The body's typed error passes through unchanged. The async form
takes `#isolation`, so the body needn't be `Sendable` and doesn't hop
executors.

**Unobserved, a span costs one load.** The body runs directly: no clock,
no metadata built, no context bound. Observed, the body runs in a child
`ServiceContext` carrying the span's id and its parent's, so every event
and span inside it, across child tasks too, knows where it came from.
`Task.detached` doesn't inherit it, as with swift-distributed-tracing.

`SpanHandle` is noncopyable, so it can't be kept past the body. The design
wanted it non-escapable as well; Swift 6.3 can't construct a `~Escapable`
value without an experimental feature (DECISIONS.md).

## Metrics

A metric is a definition, not a call. It says which event, which field,
and which tags, and a reporter turns it into a handler:

```swift
let metrics: [TelemetryMetric] = [
    .counter(QuerySpan.Stop.self),
    .distribution(QuerySpan.Stop.self, \.duration, unit: .milliseconds, tags: \.table),
    .sum(Query.self, \.rows, tags: \.table),
    .lastValue(PoolStats.self, \.idle),
    .counter(QuerySpan.Exception.self, tags: \.errorType, keep: { $0.table != "audit" }),
]
```

- **Type-checked.** The measured field is a `TelemetryMeasurement` of
  *this* event's `Measurements`, and every tag is a `TagValue` of *its*
  `Metadata`. Tags are a parameter pack, so any number of them work.
- **Named** after the event, plus the field for a measured metric:
  `hangar.query.stop.duration`. `name:` overrides it.
- **`keep:`** filters on the metadata before anything is recorded.
- **`TelemetryMetric.all { … }`** builds the list with `if` and `for`
  where an array literal won't do.

These are static members rather than `Counter(…)` types because
swift-metrics already has a `Counter`, and an application imports both.

### Reporting

A definition is data. `TelemetryMetric.attach(recording:id:)` turns it into
a handler that feeds a `MetricRecorder`, which is one method:

```swift
final class Printer: MetricRecorder {
    let descriptor: MetricDescriptor
    init(_ descriptor: MetricDescriptor) { self.descriptor = descriptor }
    func record(_ value: MeasurementValue, tags: [String]) {
        print(descriptor.name, descriptor.number(value), tags)
    }
}

var tokens = HandlerTokens()
for metric in metrics {
    tokens.append(try metric.attach(recording: Printer(metric.descriptor), id: "print:\(metric.descriptor.name)"))
}
```

`MetricDescriptor` carries what a backend needs: the name, kind, unit, tag
names and bucket hints. A reporter translates, and leaves aggregation to
the backend. Alula's `SwiftMetricsReporter` maps definitions onto
swift-metrics, with a cap on tag combinations; its source is a complete
example.

`buckets:` is a hint. Only a reporter whose backend takes histogram
boundaries can honor it, and swift-metrics has no API for them.

## Handlers

```swift
let token = try Telemetry.attach(QuerySpan.Stop.self, id: "slow-queries") { measurements, metadata, _ in
    if measurements.duration > .seconds(1) { slowQueries.record(metadata.table) }
}

let all = try Telemetry.attach(prefix: "hangar", id: "debug") { event in
    print(event.name)   // everything under hangar.*, whatever its type
}
```

A **typed** handler gets the payload by type, with no boxing and no
dictionary. An **erased** handler gets every event under a prefix through
`AnyEvent`, and reads fields with `forEachMeasurement` and
`forEachMetadata`. That's for logging and debugging: it pays for
existentials when it reads, which a typed handler doesn't. `EventName.all`
is the prefix of everything.

Attaching returns a noncopyable **`HandlerToken`**, and the handler stays
attached for as long as the token lives. When it's dropped, or `detach()`
is called, the handler is detached, so a test or a short-lived service
can't leak one. `persist()` keeps it for the life of the process;
`HandlerTokens` holds several. A second handler with the same `id` on the
same event is refused (`AttachError.duplicateID`).

**An event name belongs to one type.** It's an external identity: an erased
exporter, a dashboard or a log query keys on it. The first type to be
touched with a name owns it. Any other type claiming the same name is
refused: attaching to it throws `AttachError.nameConflict`, its emits go
nowhere, and a warning names both types.

### The rules

- **Handlers are synchronous.** They run on the emitting thread, in attach
  order, typed before erased, and may run concurrently on different
  threads. Emitting is legal anywhere, even inside a lock, as long as the
  handler doesn't take that lock itself.
- **Handlers are quick and don't block.** Nothing times them out; a slow
  handler slows the emitter. Move heavy work behind `Telemetry.stream`
  (below).
- **A handler that throws is detached**, and `TelemetryHandlerFailed` is
  emitted naming the event, the handler and the error type. Other handlers
  still run. A handler that *traps* crashes the process, since Swift can't
  catch a trap. This is the one real difference from the BEAM.
- **Re-entry is capped at 8.** A handler that emits, whose handler emits,
  and so on, has its nested emits dropped past that depth, with a warning
  once per event type.

### The detach guarantee

When `detach()` returns, the handler is never called again, not even by an
emit already under way on another thread. `detach` waits for such emits to
finish, which is why handlers mustn't block.

There's one exception. Detaching from *inside* a handler doesn't wait:
that thread is itself mid-emit, and two threads each detaching the other's
handler would wait on each other forever. It takes effect for every emit
that starts afterwards, and the old handler list is freed as soon as the
outermost emit on that thread finishes.

### Slow consumers

A handler runs on the emitting thread, so work that takes time (sending to
a collector, writing a file, paging someone) belongs in async code.
`Telemetry.stream` hands events over through a **bounded** buffer:

```swift
let failures = try Telemetry.stream(CacheEvents.StoreFailed.self, id: "pager", capacity: 256)
for await failure in failures.events {
    await pager.notify("cache store \(failure.metadata.operation) failed")
}
```

The handler copies the event and yields it, and nothing else runs on the
emitter. When the buffer is full, the oldest events are dropped by default
(`overflow: .dropNewest` keeps the first ones instead) and counted in
`droppedCount`. A consumer that falls behind costs a fixed amount of memory
and never slows the application. `stream(prefix:)` gives the erased form.
Dropping the subscription detaches the handler and finishes the stream.

### The context

The third argument is an `EventContext`: the `timestamp`, the
`serviceContext`, and the `spanID` of the span the event was emitted
inside. It's a view, like `AnyEvent`: noncopyable and borrowed. Each value
is read the first time a handler asks, and shared with every handler after
that. An emit whose handlers never ask (a metrics reporter never does)
pays for neither the clock nor the task-local read. `snapshot()` keeps a
copy.

## Tracing and logs

A `SpanObserver` is how a span becomes something else. It carries state
from a span's start to its end, and can change the `ServiceContext` the
body runs in, so a tracing span it starts becomes the parent of
everything inside:

```swift
let token = try Telemetry.observeSpans(prefix: "hangar", id: "tracing", MyObserver())
```

Observed spans run their bodies inside a child `ServiceContext` carrying
the span's id (`context.telemetrySpan`), so any logger's metadata provider
can stamp it on log lines. Alula's bridges include a
swift-distributed-tracing observer and a log metadata provider built on
exactly this.

## Testing

```swift
@Test func queryReportsItsTable() async throws {
    let stops = try await TelemetryTest.capture(QuerySpan.Stop.self) {
        _ = try await repository.all(User.self)
    }
    #expect(stops.map(\.metadata.table) == ["users"])
}
```

A capture sees only its own body's emits, including those from child
tasks, even with every other test in the process emitting the same events
at the same time. It binds a scope in a
task-local, and one shared handler per event type records an emit only for
the scopes current where it happens. Production pays nothing for this:
only handlers that exist during a capture read the task-local.

- `capture(E.self)` returns `[CapturedEvent<E>]`, typed.
- `capture(prefix:)` returns `[CapturedAnyEvent]`, with fields by name
  (`event[metadata: "outcome"]`).
- `captureSpans(S.self)` returns every phase.
- `expectNoEmission(prefix:)` throws, listing what was emitted, which fails
  the test under any framework.

Not captured: work that leaves structured concurrency, such as
`Task.detached` or a NIO event loop that doesn't carry task-locals across.

## Performance

These are the spec's targets, measured by `Benchmarks/` in a release build
on x86_64 Linux:

| | Target | Measured | Allocations |
|---|---|---|---|
| emit, nothing attached | ≤ 2 ns | ~1.7 ns | 0 |
| span, nothing attached (overhead) | ≤ 5 ns | ~1.8 ns | 0 |
| emit, unrelated to an attached prefix | ≤ 2 ns | ~1.9 ns | 0 |
| span, unrelated to an observed prefix | ≤ 5 ns | ~2.0 ns | 0 |
| emit, one typed no-op handler | ≤ 40 ns | ~23 ns | 0 |
| emit, one erased no-op handler | ≤ 80 ns | ~53 ns | 0 |

```sh
cd Benchmarks && swift run -c release TelemetryBenchmarks
```

It exits non-zero on a miss. CI enforces the allocation counts on every
push. A 2 ns line can't be held on a shared runner, so latency is enforced
before a release, on a quiet machine.

How it gets there:

- **One word on the fast path.** Each event type has a slot, and its
  flags word says whether typed handlers exist, and whether an erased
  handler's prefix matches it. The registry sets that bit only on the slots
  a prefix matches. A new slot takes its bit when it's created, so a log
  bridge on `cache` costs `hangar.query` nothing. Spans work the
  same way, through one word per span.
- **No lock to read.** An emit reads the published handler list after one
  atomic increment and leaves with one decrement, however many handlers
  there are. Attaching and detaching swap the list and wait out a grace
  period before freeing the old one; that wait is also the detach
  guarantee.
- **A lazy context.** The clock and the task-local are read only if a
  handler asks.
- **Specialized.** The dispatch loop is inlined at the emit, so handlers
  get the payload's concrete types with no generic copies.

## The laws

1. **Telemetry describes facts that already happened.** It doesn't
   command behavior. An event is past tense: a session was created, a
   query finished.
2. **Application correctness never depends on a telemetry consumer.**
   Removing every handler must not change what the application does. An
   order being placed or an invoice being paid is a domain event, and it
   belongs in your domain model, a queue or an outbox. It must not be
   carried by a synchronous, global, best-effort observation mechanism that
   drops events when a buffer is full.
3. **Instrumented code doesn't choose the backend.** Libraries emit.
   Applications decide.
4. **A narrow observer imposes no global cost.** A prefix costs only the
   events beneath it.
5. **Emitting doesn't require a framework.** That's why this is its own
   package: a library depends on it, and on nothing else.

## For library authors

- Depend on `TelemetryCore` (or `TelemetryMacros`) alone. Never bootstrap a
  backend, and never attach a handler in library code. Those are the
  application's to decide.
- Put events in a public namespace, document them, and treat them as API.
- Use spans for operations with a duration, and events for things that
  happen at a point in time.
- Keep metadata low-cardinality. Put anything unbounded (SQL, ids, user
  input) in an optional field, filled only when a setting asks for it.
- Publish metric definitions (`[TelemetryMetric]`) for your events, so an
  application can report them without writing its own. In Alula, a module
  that holds them contributes them automatically.

## Not here

- **A poller.** A periodic job that emits is one, and every application
  already has a way to run work on an interval.
- **`@Instrumented`**, the body macro that would wrap a function in a span.
  It's deferred, and `Telemetry.span` is the supported path.
- **Summaries** (client-side quantiles). Backends compute quantiles from
  histograms better than a client can.

## License

MIT. See [LICENSE](LICENSE).
