// swift-tools-version: 6.2
import PackageDescription

// Capture core for Echo-3 bundles, taken from the MIT-0 licensed
// spaitial-ai/spaitial-capture-prototype ("Full" guidance setup) and extended
// with Cosmic-specific LiDAR persistence. See docs/echo3-capture-plan.md.
let package = Package(
    name: "CosmicCapture",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CosmicCapture", targets: ["CosmicCapture"])
    ],
    targets: [
        .target(
            name: "CosmicCapture",
            path: "Sources/CosmicCapture"
        ),
        .testTarget(
            name: "CosmicCaptureTests",
            dependencies: ["CosmicCapture"],
            path: "Tests/CosmicCaptureTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
