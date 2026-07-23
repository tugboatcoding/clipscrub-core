// swift-tools-version: 6.0
import PackageDescription

// ClipscrubKit is the redaction engine behind ClipScrub (https://clipscrub.com):
// detection, redaction and pseudonymisation, plus the `clipscrub` CLI. A SwiftPM
// package with no UI and no third-party dependencies. Test headlessly: `swift test`.
let package = Package(
    name: "ClipscrubKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipscrubKit", targets: ["ClipscrubKit"]),
        // Headless smoke harness — runs the core checks under Command Line Tools
        // (`swift run ClipscrubVerify`), where XCTest/Testing are unavailable.
        .executable(name: "ClipscrubVerify", targets: ["ClipscrubVerify"]),
        // Local redaction CLI: text (stdin→stdout) + image (file→file). The deterministic
        // rules are the floor, with an optional on-device model pass on top. A redaction
        // gate you put in front of things, not an LLM/MCP tool you pump data at.
        .executable(name: "clipscrub", targets: ["clipscrub"]),
    ],
    targets: [
        .target(
            name: "ClipscrubKit",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ClipscrubVerify",
            dependencies: ["ClipscrubKit"]
        ),
        .executableTarget(
            name: "clipscrub",
            dependencies: ["ClipscrubKit"]
        ),
        // Full XCTest suite — runs in Xcode / a full toolchain (`swift test`).
        .testTarget(
            name: "ClipscrubKitTests",
            dependencies: ["ClipscrubKit"]
        ),
    ]
)
