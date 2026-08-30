// swift-tools-version: 6.0
import PackageDescription

// Spike only. Language mode v5 on purpose: proving capture feasibility is the
// job here, not satisfying the Swift 6 concurrency checker. v1 gets the real
// actor boundaries.
let package = Package(
    name: "vigil",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "vigil",
            path: "Sources/vigil",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
