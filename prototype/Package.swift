// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mouseless",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mouseless",
            path: "Sources/Mouseless"
        )
    ]
)
