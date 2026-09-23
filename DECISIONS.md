# Decisions

The judgement calls behind this package: each with the alternatives it was
chosen over, and what reversing it would cost. Newest first. This package
began inside Alula, and that history (the original spec, the first audit)
is in Alula's DECISIONS.md, D42 and D43.

---

## T4 — The laws

Telemetry is observational only. These rules hold the design together, and
a change that breaks one is wrong even if it compiles:

1. **Telemetry describes facts that already happened.** It doesn't command
   behavior.
2. **Application correctness never depends on a consumer.** Removing every
   handler must not change what an application does. A domain event, such
   as an order placed, belongs in the domain, not here: handlers are
   synchronous, global and best-effort, and a bounded stream drops events.
3. **Instrumented code doesn't choose the backend.** Libraries emit.
   Applications decide.
4. **A narrow observer imposes no global cost** (T2).
5. **Emitting doesn't require a framework** (T1).

---

## T3 — Where the spec was departed from, and why

The spec is swift-telemetry's original design document, from Alula D42.

1. **`SpanHandle` is `~Copyable`, not `~Escapable`.** The spec allowed this
   fallback if it asked for a reproducer. On Swift 6.3.3:

   ```swift
   struct H: ~Copyable, ~Escapable { @_lifetime(immortal) init() {} }
   // error: an initializer cannot return a ~Escapable result
   ```

   `@_lifetime` needs the experimental `Lifetimes` feature. Revisit when
   lifetime dependencies are stable.
2. **`EventContext` is a lazy, noncopyable view.** The spec reads the clock
   and `ServiceContext.current` once per emit. That measured 15 ns plus
   13 ns of a 40 ns budget, spent on values a metrics handler never reads.
   Each value is now read on first access and shared, and `snapshot()`
   keeps a copy.
3. **Metric definitions are static members (`.counter(…)`).** A
   `Counter(…)` type would collide with swift-metrics' `Counter` in every
   application that imports both.
4. **A span's `start` measurement is `monotonicTime: Duration`**, measured
   from a process reference. `ContinuousClock.Instant` isn't a
   measurement.
5. **Test helpers throw rather than assert.** `expectNoEmission` throws,
   which fails a test under any framework without importing one.
6. **No poller.** An application's scheduler plus an emit is one.
   `@Instrumented` is deferred, as the spec's open questions allow.

---

## T2 — The hot path

**Targets.** These are the spec's numbers, measured by `Benchmarks/`, all
with zero allocations:

| Scenario | Target | Measured |
| --- | --- | --- |
| nothing attached | ≤2 ns | 1.6–1.9 ns |
| unobserved span | ≤5 ns | ~1.9 ns |
| one typed handler | ≤40 ns | ~23 ns |
| one erased handler | ≤80 ns | ~53 ns |

The spec's default design, a mutex snapshot per emit, measured 233 ns with
one typed handler. The measured cost of each piece:

| Piece | Cost |
| --- | --- |
| mutex plus array retain | 36 ns |
| per-handler in-flight atomics | 15.5 ns |
| clock | 15 ns |
| task-local | 13 ns |
| seven pthread-key calls | ~12 ns |

On top of those, the dispatch ran unspecialized across the module boundary.

**What replaced it.**

- **One flags word per slot.** Typed handlers set one bit. An erased
  handler's prefix sets another, only on the slots it matches. The span
  macro gives each span a flags word of its own.
- **Prefix matching happens at attach and at slot creation, never per
  emit.** A narrow prefix costs other events nothing. When it was a global
  bit, one narrow prefix made every unrelated span cost 908 ns and 3
  allocations.
- **RCU for typed handlers.** An emit increments one of two epoch counters
  and reads the published list without a lock. Attach and detach swap the
  list and wait out a two-flip grace period before freeing the old one.
  That wait is also the detach guarantee.
  - A detach from inside a handler doesn't wait: two threads each
    detaching the other's handler would deadlock. The old list is freed
    when the outermost emit on that thread ends.
  - Erased handlers keep a per-entry Dekker check, because they're cached
    on every slot they match.
- **An `@inlinable` typed dispatch**, so handlers are called specialized,
  and **one thread-state pointer** instead of per-concern thread locals.

**Benchmarking at this scale.** Code placement moves results by a quarter
of a nanosecond. Two copies of the same emit, compiled into two closures,
measured 1.9 and 2.2 ns. Scenarios that run the same code share one
closure, and a comparison between versions uses the same benchmark
binary.

**ThreadSanitizer can't see `Synchronization.Mutex` on Linux.** The
reproducer, on Swift 6.3.3: four threads appending to an array only inside
`Mutex.withLock` produce "Swift access race". The lock's handoff happens in
the uninstrumented standard library, through a futex. So the package locks
with a pthread mutex (`Lock`), which TSan intercepts. That's its one
`@unchecked Sendable`. Never give it `Void` state: a zero-sized field
aliases the lock's own storage, and TSan reports the overlap.

**Event names belong to one type.** A slot claims its name when it's
created. A second type with the same name is refused: attaching to it
throws `AttachError.nameConflict`, and its emits are dropped, with a
warning naming both types.

---

## T1 — Its own package, and three modules

**Chosen.** swift-telemetry is a package of its own, outside Alula. A
library that emits (Hangar, a driver, anything) depends on it and on
nothing else. Alula depends on it too, and keeps what is Alula's: the
bridges to swift-metrics, swift-distributed-tracing and swift-log, and the
module that wires them from configuration.

**Modules.**

- **`TelemetryCore`**: events, spans, handlers, metric definitions and the
  bounded stream. It depends on swift-service-context and nothing else.
- **`TelemetryMacros`**: the macros. It re-exports the core, so a library
  using them imports one module. Its swift-syntax dependency is paid only
  by those who use the macros. Every conformance the macros write can be
  written by hand.
- **`TelemetryTesting`**: capture, isolated per test.

None of them is named `Telemetry`. That's the name of the type every call
site writes (`Telemetry.emit`), and a module sharing a type's name breaks
qualified lookup. swift-changeset's module is `Changesets` for the same
reason.

**Why.** An independent audit of Alula 0.34 found that keeping the neutral
core inside the alula package would make every library that emits a
Alula dependent. Hangar is deliberately usable without Alula. The core
depended only on swift-service-context, so extracting it was mechanical;
doing it before anyone outside Alula adopted it made it free.

**Cost of reversing.** Folding it back into Alula means one product and
three renames, and every independent adopter would have to take on Alula.
