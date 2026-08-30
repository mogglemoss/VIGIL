// swift-tools-version: 6.0
import PackageDescription

// Spike only. Language mode v5 on purpose: proving capture feasibility is the
// job here, not satisfying the Swift 6 concurrency checker. v1 gets the real
// actor boundaries.
let package = Package(
    name: "observance",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "observance",
            path: "Sources/observance",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
