// swift-tools-version: 6.3
import PackageDescription

// Not part of swift-telemetry: benchmarks build in release, depend on the
// package by path, and would otherwise put an executable and a malloc
// interposer into every consumer's graph.
//
//     swift run -c release TelemetryBenchmarks
//
// Exits non-zero when a target in the telemetry spec is missed — an
// allocation always, a latency unless `--no-latency` (for a noisy runner).
let package = Package(
    name: "telemetry-benchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
    ],
    targets: [
        // Counts allocations on the calling thread. glibc only: it wraps
        // malloc and friends around __libc_malloc. Elsewhere it reports
        // itself unsupported and the allocation checks are skipped, loudly.
        .target(name: "CAllocationCounter", path: "Sources/CAllocationCounter"),
        .executableTarget(
            name: "TelemetryBenchmarks",
            dependencies: [
                .product(name: "TelemetryMacros", package: "swift-telemetry"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                "CAllocationCounter",
            ],
            path: "Sources/TelemetryBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
