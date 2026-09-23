// swift-tools-version: 6.3
// Swift Telemetry — typed events and spans: libraries say what happened,
// applications decide what it becomes. Modelled on Elixir's :telemetry.
//
// Neutral by design. Nothing here knows about Alula, Hangar or any backend:
// a library depends on TelemetryCore to emit, and never on a framework.
// Reporting to swift-metrics, swift-distributed-tracing and swift-log lives
// with whoever composes the application — Alula's AlulaTelemetryBridges,
// for one.
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-telemetry",
    // Synchronization's Atomic and the noncopyable views are macOS 15+.
    platforms: [.macOS(.v15)],
    products: [
        // Events, spans, handlers, metric definitions. swift-service-context
        // is its only dependency; no macros, so no swift-syntax.
        //
        // Module names are not `Telemetry`, because that is the name of the
        // type every caller writes (`Telemetry.emit`), and a module sharing
        // a type's name breaks qualified lookup — the same reason
        // swift-changeset's module is `Changesets`.
        .library(name: "TelemetryCore", targets: ["TelemetryCore"]),
        // @TelemetryEvent, @TelemetrySpan, @TelemetryFields. Re-exports
        // TelemetryCore, so one import covers a library that uses them.
        .library(name: "TelemetryMacros", targets: ["TelemetryMacros"]),
        // Per-test capture, isolated between parallel tests.
        .library(name: "TelemetryTesting", targets: ["TelemetryTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
        // swift-syntax bumps its major with each Swift release; the open
        // range is the community convention for macro packages.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
    ],
    targets: [
        .target(
            name: "TelemetryCore",
            dependencies: [.product(name: "ServiceContextModule", package: "swift-service-context")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .macro(
            name: "TelemetryMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TelemetryMacros",
            dependencies: ["TelemetryCore", "TelemetryMacrosImpl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TelemetryTesting",
            dependencies: ["TelemetryCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TelemetryCoreTests",
            dependencies: [
                "TelemetryCore", "TelemetryMacros", "TelemetryTesting",
                .product(name: "ServiceContextModule", package: "swift-service-context"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // SwiftSyntaxMacrosGenericTestSupport, not SwiftSyntaxMacrosTestSupport:
        // the latter reports through XCTFail; the generic one hands failures
        // back, so they record as swift-testing issues. See
        // SwiftTestingBridge.swift.
        .testTarget(
            name: "TelemetryMacrosTests",
            dependencies: [
                "TelemetryMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// Documentation tooling only, gated so that consumers never resolve it.
//
//     TELEMETRY_BUILD_DOCS=1 swift package generate-documentation
import Foundation
if ProcessInfo.processInfo.environment["TELEMETRY_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0"))
}

// Warnings are errors in CI, for this package's own targets only:
//
//     TELEMETRY_STRICT_WARNINGS=1 swift build
//
// `-Xswiftc -warnings-as-errors` would apply to dependencies too, and fail
// on a warning a newer compiler found in someone else's code.
if ProcessInfo.processInfo.environment["TELEMETRY_STRICT_WARNINGS"] != nil {
    for target in package.targets where target.type != .plugin {
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        target.swiftSettings = settings
    }
}
