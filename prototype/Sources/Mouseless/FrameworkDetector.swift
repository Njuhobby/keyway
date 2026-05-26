import Cocoa
import ApplicationServices

/// Classifies an app by its UI framework. Drives the OmniParser routing
/// decision: AppKit / SwiftUI apps usually have decent AX coverage and
/// stay on the AX-only path; Catalyst / Electron / WebContent shells
/// have AX black holes inside their window content and route the
/// focused-app-children scan to the OmniParser visual path.
///
/// See `specs/omniparser-fallback-design.md` §4.4 for the rationale
/// behind "framework detection > count threshold" and §4.2 for how
/// the result feeds `collectAll()`.
enum AppFramework: String {
    /// Pure AppKit / SwiftUI / mostly-native — focused-app AX walk
    /// stays as the primary source.
    case appkit
    /// UIKit-bridged-to-macOS — sparse AX coverage of focused-app
    /// children. Routes focused-app source to OmniParser.
    case catalyst
    /// Chromium-based shell — AX content is a flat sea of AXGroup.
    /// Routes focused-app source to OmniParser.
    case electron
    /// Native shell hosting a WKWebView or similar — focused-app AX
    /// coverage depends on the embedded site's ARIA hygiene, usually
    /// poor. Routes focused-app source to OmniParser. Examples: New
    /// Outlook for Mac, Teams, OneNote (newer versions).
    case webContent
    /// Detection ran but couldn't classify. Behavior is the same as
    /// `appkit` (try AX walk, fall back to OmniParser if AX returns
    /// suspiciously few candidates). Logged so we can investigate.
    case unknown
}

@MainActor
enum FrameworkDetector {
    // MARK: - Cache

    /// App frameworks don't change at runtime (or even between launches
    /// of the same app version). One detection per bundleID, kept for
    /// the lifetime of Mouseless. Survives app restarts (the bundle on
    /// disk doesn't change), gets re-checked next time Mouseless
    /// itself restarts.
    private static var cache: [String: AppFramework] = [:]

    // MARK: - Public

    /// Detect the framework of `app`. `bundleID` is used as cache key.
    /// `axElement` is the app's AX element (from
    /// `AXUIElementCreateApplication(pid)`) — needed only by Layer 2.
    /// Always returns a value (never throws); on truly inscrutable
    /// apps returns `.unknown`.
    static func detect(bundleID: String,
                       bundleURL: URL?,
                       axElement: AXUIElement) -> AppFramework {
        if let cached = cache[bundleID] {
            return cached
        }

        let result: AppFramework
        let layer: String

        // Layer 1: bundle layout. 0 IPC, pure filesystem reads. Hits
        // most Catalyst / Electron apps.
        if let url = bundleURL, let l1 = layer1(bundleURL: url) {
            result = l1
            layer = "Layer1"
        }
        // Layer 2: AX tree probe for AXWebArea. ~10-20 IPCs once.
        // Catches WKWebView-wrapped shells that Layer 1 misses
        // (New Outlook, Teams, OneNote new versions).
        else if layer2HasWebArea(app: axElement) {
            result = .webContent
            layer = "Layer2"
        }
        // No signal — treat as AppKit (with safety net at collectAll
        // for "AX returned suspiciously few candidates").
        else {
            result = .appkit
            layer = "default"
        }

        cache[bundleID] = result
        print("[mouseless] framework: \(bundleID) -> \(result.rawValue) (\(layer))")
        return result
    }

    /// Clear the cache. For testing — currently unused in production
    /// because we don't know when an app's framework would change
    /// within Mouseless's lifetime.
    static func resetCache() {
        cache.removeAll()
    }

    /// P3 debug: detect the framework of the currently focused app and
    /// log the result. Doesn't change routing — that's P4. Just lets
    /// us verify the detector returns the right framework on the test
    /// matrix (Finder = appkit, WeChat = electron, Music = catalyst,
    /// New Outlook = webContent, etc.).
    /// Strip the call site once P4 wires real routing.
    static func debugDetectFocused() {
        let sys = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, "AXFocusedApplication" as CFString, &appRef) == .success,
              let appRaw = appRef
        else {
            print("[mouseless] framework: no focused application")
            return
        }
        let app = appRaw as! AXUIElement

        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        guard let running = NSRunningApplication(processIdentifier: pid),
              let bundleID = running.bundleIdentifier
        else {
            print("[mouseless] framework: focused app has no bundleID (pid=\(pid))")
            return
        }
        _ = detect(bundleID: bundleID, bundleURL: running.bundleURL, axElement: app)
    }

    // MARK: - Layer 1: bundle inspection

    /// Returns a framework iff bundle layout gives a confident signal,
    /// nil otherwise (meaning "fall through to Layer 2").
    private static func layer1(bundleURL: URL) -> AppFramework? {
        // Catalyst: Info.plist carries UIKit-era keys that AppKit
        // apps don't have. UIDeviceFamily is the canonical signal —
        // Catalyst apps inherit it from their iOS Info.plist. The
        // build pipeline adds it; AppKit-only apps never have it.
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOf: infoPlistURL) {
            if plist["UIDeviceFamily"] != nil || plist["LSRequiresIPhoneOS"] != nil {
                return .catalyst
            }
        }

        // Electron: ships its own Chromium runtime as a framework, plus
        // the app code packaged as an asar archive. Either marker is
        // conclusive — these files don't appear in non-Electron apps.
        let electronFrameworkURL = bundleURL.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework"
        )
        let asarURL = bundleURL.appendingPathComponent("Contents/Resources/app.asar")
        if FileManager.default.fileExists(atPath: electronFrameworkURL.path)
            || FileManager.default.fileExists(atPath: asarURL.path) {
            return .electron
        }

        return nil
    }

    // MARK: - Layer 2: AX tree probe

    private static let layer2MaxDepth = 5

    /// BFS the app's AX tree to a shallow depth, return true if any
    /// node has role `AXWebArea`. This is the WebKit / Chromium AX
    /// bridge's standard label for "this subtree is web content".
    /// Catches WKWebView-wrapped native shells whose bundle layout
    /// looks like a normal AppKit app (no Electron Framework, no
    /// Catalyst Info.plist key) but whose main UI is web content.
    ///
    /// We limit depth because a deep BFS on apps with thousands of
    /// AX nodes (Slack, Notion) would defeat the "cheap detection"
    /// premise.
    ///
    /// Depth 5: empirically Tauri / WKWebView shells can bury the
    /// AXWebArea node a few levels deeper than the obvious "window
    /// → contentView → AXWebArea" shape. Depth 3 missed Clash Verge
    /// (Tauri) in testing, depth 5 should cover it. Cost: per-app
    /// once + cached forever, so doesn't matter for runtime hot path.
    ///
    /// On miss, dumps every role seen at every depth — diagnostic
    /// for figuring out where the AXWebArea (if any) is hiding.
    private static func layer2HasWebArea(app: AXUIElement) -> Bool {
        var frontier: [(AXUIElement, Int)] = [(app, 0)]
        var seenRoles: [Int: Set<String>] = [:]   // depth -> set of roles
        while !frontier.isEmpty {
            let (node, depth) = frontier.removeFirst()
            if depth > layer2MaxDepth { continue }

            var roleRef: CFTypeRef?
            let role: String? = {
                if AXUIElementCopyAttributeValue(node, "AXRole" as CFString, &roleRef) == .success {
                    return roleRef as? String
                }
                return nil
            }()
            if let r = role {
                seenRoles[depth, default: []].insert(r)
                if r == "AXWebArea" {
                    return true
                }
            }

            if depth < layer2MaxDepth {
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, "AXChildren" as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        frontier.append((child, depth + 1))
                    }
                }
            }
        }
        // No AXWebArea found anywhere within depth budget. Dump the
        // BFS shape so we can see what *was* there — useful for
        // diagnosing whether the WKWebView is just deeper than our
        // budget, or genuinely absent (custom-rendered NSView app).
        let summary = (0...layer2MaxDepth).map { d in
            "d\(d)=[\(seenRoles[d, default: []].sorted().joined(separator: ","))]"
        }.joined(separator: " ")
        print("[mouseless] framework: Layer 2 BFS miss: \(summary)")
        return false
    }
}
