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
        ),
        // Chrome Native Messaging host — pure stdio ↔ Unix socket relay.
        // Spawned by the browser when our extension calls
        // `chrome.runtime.connectNative('com.mouseless.bridge')`. Talks
        // chrome's native-messaging framing on stdin/stdout (4-byte
        // native-uint32 length + UTF-8 JSON body) and the same framing on
        // the socket to Mouseless main process — bytes flow through
        // untouched. See specs/browser-support-design.md.
        .executableTarget(
            name: "mouseless-bridge",
            path: "Sources/mouseless-bridge"
        )
    ]
)
