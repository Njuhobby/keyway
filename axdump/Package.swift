// swift-tools-version:5.9
import PackageDescription

// Standalone AX-tree inspector — a dev tool for Mouseless's AX-coverage
// work, kept OUT of the Mouseless app on purpose (no runtime cost, no
// trigger-key juggling). Builds to a stable .build path so you grant it
// Accessibility once. See README.md.
let package = Package(
    name: "axdump",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "axdump", path: "Sources/axdump")
    ]
)
