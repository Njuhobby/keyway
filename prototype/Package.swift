// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mouseless",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mouseless",
            path: "Sources/Mouseless",
            resources: [
                // OmniParser-v2.0 icon detector, exported to CoreML via the
                // P1 spike. 39MB. Bundled into the .app so OmniParser path
                // runs without network or external dependency. Used by
                // OmniParserModel.swift for inference on focused-window
                // screenshots (P5+).
                .copy("icon_detect.mlpackage")
            ]
        )
    ]
)
