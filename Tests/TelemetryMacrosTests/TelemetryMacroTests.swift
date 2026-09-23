import TelemetryMacrosImpl
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

private let specs: [String: MacroSpec] = [
    "TelemetryEvent": MacroSpec(type: TelemetryEventMacro.self, conformances: ["TelemetryEvent"]),
    "TelemetrySpan": MacroSpec(type: TelemetrySpanMacro.self, conformances: ["SpanEvent"]),
    "TelemetryFields": MacroSpec(type: TelemetryFieldsMacro.self, conformances: ["TelemetryFields"]),
    "TelemetryMeasurements": MacroSpec(
        type: TelemetryMeasurementsMacro.self, conformances: ["TelemetryFields"]),
]

@Suite("Telemetry macro expansion")
struct TelemetryMacroExpansionTests {
    @Test("a bare event: name, slot, conformance")
    func bareEvent() {
        assertMacroExpansion(
            """
            @TelemetryEvent("app.sessions.created")
            public enum SessionCreated {}
            """,
            expandedSource: """
                public enum SessionCreated {

                    public static let name: TelemetryCore.EventName = "app.sessions.created"

                    public static let _slot = TelemetryCore.HandlerSlot<SessionCreated>()
                }

                extension SessionCreated: TelemetryCore.TelemetryEvent {
                }
                """,
            macroSpecs: specs)
    }

    @Test("nested structs are marked by name; hand-marked ones are left alone")
    func marksNestedStructs() {
        assertMacroExpansion(
            """
            @TelemetryEvent("hangar.query")
            enum Query {
                struct Measurements {
                    var rows: Int
                }
                struct Metadata {
                    var table: String
                }
                @TelemetryFields struct Other {
                    var x: Int
                }
            }
            """,
            expandedSource: """
                enum Query {
                    struct Measurements {
                        var rows: Int
                    }
                    struct Metadata {
                        var table: String
                    }
                    struct Other {
                        var x: Int
                    }

                    static let name: TelemetryCore.EventName = "hangar.query"

                    static let _slot = TelemetryCore.HandlerSlot<Query>()
                }

                extension Query.Measurements: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.measurement("rows", rows)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.rows:
                            "rows"
                        default:
                            nil
                        }
                    }
                }

                extension Query.Metadata: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("table", table)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.table:
                            "table"
                        default:
                            nil
                        }
                    }
                }

                extension Query.Other: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("x", x)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.x:
                            "x"
                        default:
                            nil
                        }
                    }
                }

                extension Query: TelemetryCore.TelemetryEvent {
                }
                """,
            macroSpecs: specs)
    }

    @Test("a public fields struct gets a public memberwise init; computed and static properties are not fields")
    func publicFields() {
        assertMacroExpansion(
            """
            @TelemetryFields
            public struct RequestMetadata {
                public var requestID: String
                public var retries: Int = 0
                public let version = 1
                public var summary: String { requestID }
                public static var shared = 0
            }
            """,
            expandedSource: """
                public struct RequestMetadata {
                    public var requestID: String
                    public var retries: Int = 0
                    public let version = 1
                    public var summary: String { requestID }
                    public static var shared = 0

                    public init(requestID: String, retries: Int = 0) {
                        self.requestID = requestID
                        self.retries = retries
                    }
                }

                extension RequestMetadata: TelemetryCore.TelemetryFields {
                    public func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("request_id", requestID)
                        encoder.value("retries", retries)
                        encoder.value("version", version)
                    }

                    public static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.requestID:
                            "request_id"
                        case \\Self.retries:
                            "retries"
                        case \\Self.version:
                            "version"
                        default:
                            nil
                        }
                    }
                }
                """,
            macroSpecs: specs)
    }

    @Test("a span: phases with flattened metadata, kind, and the SpanEvent requirements")
    func span() {
        assertMacroExpansion(
            """
            @TelemetrySpan("hangar.query", kind: .client)
            enum Query {
                struct Metadata {
                    var table: String
                }
                struct StopMetadata {
                    var rows: Int = 0
                }
            }
            """,
            expandedSource: """
                enum Query {
                    struct Metadata {
                        var table: String
                    }
                    struct StopMetadata {
                        var rows: Int = 0
                    }

                    static let name: TelemetryCore.EventName = "hangar.query"

                    static let _spanFlags = TelemetryCore.SpanFlags(name: "hangar.query")

                    static var kind: TelemetryCore.TelemetrySpanKind {
                        .client
                    }

                    enum Start: TelemetryCore.TelemetryEvent {
                        typealias Measurements = TelemetryCore.SpanStartMeasurements
                        typealias Metadata = Query.Metadata
                        static let name: TelemetryCore.EventName = "hangar.query.start"
                        static let _slot = TelemetryCore.HandlerSlot<Start>(span: Query._spanFlags, phase: .start)
                    }

                    enum Stop: TelemetryCore.TelemetryEvent {
                        typealias Measurements = TelemetryCore.SpanDurationMeasurements
                        struct Metadata: TelemetryCore.TelemetryFields {
                            let table: String
                            let rows: Int
                            func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                                encoder.value("table", table)
                                encoder.value("rows", rows)
                            }
                            static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                                switch keyPath {
                                case \\Self.table:
                                    "table"
                                case \\Self.rows:
                                    "rows"
                                default:
                                    nil
                                }
                            }
                        }
                        static let name: TelemetryCore.EventName = "hangar.query.stop"
                        static let _slot = TelemetryCore.HandlerSlot<Stop>(span: Query._spanFlags, phase: .stop)
                    }

                    enum Exception: TelemetryCore.TelemetryEvent {
                        typealias Measurements = TelemetryCore.SpanDurationMeasurements
                        struct Metadata: TelemetryCore.TelemetryFields {
                            let table: String
                            let errorType: String
                            let rows: Int
                            func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                                encoder.value("table", table)
                                encoder.value("error_type", errorType)
                                encoder.value("rows", rows)
                            }
                            static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                                switch keyPath {
                                case \\Self.table:
                                    "table"
                                case \\Self.errorType:
                                    "error_type"
                                case \\Self.rows:
                                    "rows"
                                default:
                                    nil
                                }
                            }
                        }
                        static let name: TelemetryCore.EventName = "hangar.query.exception"
                        static let _slot = TelemetryCore.HandlerSlot<Exception>(span: Query._spanFlags, phase: .exception)
                    }

                    static func initialStopMetadata() -> StopMetadata {
                        StopMetadata()
                    }

                    static func stopMetadata(_ metadata: Metadata, _ stop: StopMetadata) -> Stop.Metadata {
                        Stop.Metadata(table: metadata.table, rows: stop.rows)
                    }

                    static func exceptionMetadata(_ metadata: Metadata, _ stop: StopMetadata, errorType: String) -> Exception.Metadata {
                        Exception.Metadata(table: metadata.table, errorType: errorType, rows: stop.rows)
                    }
                }

                extension Query.Metadata: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("table", table)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.table:
                            "table"
                        default:
                            nil
                        }
                    }
                }

                extension Query.StopMetadata: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("rows", rows)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.rows:
                            "rows"
                        default:
                            nil
                        }
                    }
                }

                extension Query: TelemetryCore.SpanEvent {
                }
                """,
            macroSpecs: specs)
    }

    @Test("snake_case: acronyms and digits")
    func snakeCase() {
        // Through the macro, so the rule under test is the one that ships.
        assertMacroExpansion(
            """
            @TelemetryFields
            struct M {
                var userID: Int
                var requestURLPath: Int
                var http2Frames: Int
                var a: Int
            }
            """,
            expandedSource: """
                struct M {
                    var userID: Int
                    var requestURLPath: Int
                    var http2Frames: Int
                    var a: Int
                }

                extension M: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("user_id", userID)
                        encoder.value("request_url_path", requestURLPath)
                        encoder.value("http2_frames", http2Frames)
                        encoder.value("a", a)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.userID:
                            "user_id"
                        case \\Self.requestURLPath:
                            "request_url_path"
                        case \\Self.http2Frames:
                            "http2_frames"
                        case \\Self.a:
                            "a"
                        default:
                            nil
                        }
                    }
                }
                """,
            macroSpecs: specs)
    }
}

@Suite("Telemetry macro diagnostics")
struct TelemetryMacroDiagnosticTests {
    private func expectDiagnostic(
        _ source: String, expanded: String, _ message: String, line: Int, column: Int,
        fileID: StaticString = #fileID, filePath: StaticString = #filePath,
        testLine: UInt = #line, testColumn: UInt = #column
    ) {
        assertMacroExpansion(
            source, expandedSource: expanded,
            diagnostics: [DiagnosticSpec(message: message, line: line, column: column)],
            macroSpecs: specs, fileID: fileID, filePath: filePath, line: testLine, column: testColumn)
    }

    @Test("a bad name, and a non-literal one — and no conformance to bury them")
    func names() {
        expectDiagnostic(
            """
            @TelemetryEvent("Hangar.Query")
            enum Q {}
            """,
            expanded: "enum Q {}",
            """
            'Hangar.Query' is not a valid event name: use lowercase segments separated by dots, \
            each starting with a letter, such as "db.query" or "http.request.stop".
            """,
            line: 1, column: 17)
        expectDiagnostic(
            """
            @TelemetryEvent("hangar.\\(x)")
            enum Q {}
            """,
            expanded: "enum Q {}",
            """
            @TelemetryEvent's name must be a plain string literal — it is checked here, at build \
            time, and it must be the same on every run.
            """,
            line: 1, column: 17)
    }

    @Test("not an enum, an enum with cases, class fields")
    func shape() {
        expectDiagnostic(
            """
            @TelemetryEvent("a.b")
            struct Q {}
            """,
            expanded: "struct Q {}",
            """
            @TelemetryEvent can only be attached to an enum with no cases — the type is the \
            event's name, and is never instantiated. Write 'enum' here.
            """,
            line: 1, column: 1)
        expectDiagnostic(
            """
            @TelemetryEvent("a.b")
            enum Q {
                case one
            }
            """,
            expanded: """
                enum Q {
                    case one
                }
                """,
            """
            An @TelemetryEvent enum has no cases — the type is the event's name, and is never \
            instantiated. Carry these values as Metadata fields instead.
            """,
            line: 3, column: 5)
        expectDiagnostic(
            """
            @TelemetryEvent("a.b")
            enum Q {
                final class Metadata {}
            }
            """,
            expanded: """
                enum Q {
                    final class Metadata {}
                }
                """,
            """
            Metadata must be a struct: event fields are values, copied to every handler and \
            across threads.
            """,
            line: 3, column: 11)
    }

    @Test("span stop metadata needs defaults, and may not clash with the span's")
    func spanFields() {
        expectDiagnostic(
            """
            @TelemetrySpan("a.b")
            enum Q {
                struct StopMetadata {
                    var rows: Int
                }
            }
            """,
            expanded: """
                enum Q {
                    struct StopMetadata {
                        var rows: Int
                    }
                }

                extension Q.StopMetadata: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("rows", rows)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.rows:
                            "rows"
                        default:
                            nil
                        }
                    }
                }
                """,
            """
            Give 'rows' a default value: StopMetadata exists before the body sets anything, and \
            a span that stops early reports the defaults.
            """,
            line: 4, column: 13)
        expectDiagnostic(
            """
            @TelemetrySpan("a.b")
            enum Q {
                struct Metadata {}
                struct StopMetadata {
                    var errorType: String = ""
                }
            }
            """,
            expanded: """
                enum Q {
                    struct Metadata {}
                    struct StopMetadata {
                        var errorType: String = ""
                    }
                }

                extension Q.Metadata: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        nil
                    }
                }

                extension Q.StopMetadata: TelemetryCore.TelemetryFields {
                    func encode(into encoder: inout TelemetryCore.FieldEncoder) {
                        encoder.value("error_type", errorType)
                    }

                    static func fieldName(for keyPath: PartialKeyPath<Self>) -> String? {
                        switch keyPath {
                        case \\Self.errorType:
                            "error_type"
                        default:
                            nil
                        }
                    }
                }
                """,
            """
            'errorType' is the name the exception phase gives the error's type. Rename this field.
            """,
            line: 5, column: 13)
    }

    @Test("only computed properties")
    func computedOnly() {
        expectDiagnostic(
            """
            @TelemetryFields
            struct M {
                var x: Int { 1 }
            }
            """,
            expanded: """
                struct M {
                    var x: Int { 1 }
                }
                """,
            """
            M has only computed properties, and only stored properties are encoded. Store the \
            values the event carries.
            """,
            line: 2, column: 8)
    }
}
