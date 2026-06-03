import Foundation
import CoreGraphics
import AppKit   // NSWorkspace

/// Browser-app hint source. When the frontmost app is in
/// `AppRegistry.browserBundleIDs`, `HintMode` calls
/// `BrowserProvider.fetchHints` instead of running AX walk or
/// OmniParser. The extension's content script (see
/// `prototype/extension/detector.js`) does the DOM-level enumeration
/// and ships screen-space rects back over the native messaging bridge.
///
/// Falls back gracefully when the extension isn't connected — caller
/// can then route to OP (existing behavior for un-whitelisted apps).
///
/// See `specs/browser-support-design.md` for the bigger picture.
enum BrowserProvider {
    /// One clickable element from the browser's DOM, already translated
    /// to **screen coordinates** by the extension. Rects are top-left
    /// origin in points (matches CG / AX). `tag` is the lowercased HTML
    /// element name; `text` is a short label (first 60 chars of
    /// innerText / value / aria-label / title / alt, whichever is
    /// available first).
    struct Hint: Sendable {
        let rect: CGRect
        let tag: String
        let text: String
    }

    /// Ask the browser extension for the active tab's hints. Returns
    /// `nil` if no extension is connected, the request times out, or
    /// the response is malformed — caller decides whether to fall back
    /// to OP.
    ///
    /// - parameter timeout: how long to wait for the extension's
    ///   response before giving up. 400ms is comfortable: P2 stage A
    ///   measured ~35ms on GitHub front page, so even big SPAs should
    ///   fit; longer than this and we'd rather show OP-based hints
    ///   than make the user wait staring at no overlay.
    static func fetchHints(timeout: TimeInterval = 0.4) async -> [Hint]? {
        // Pass the frontmost bundleID so BridgeServer's send-side guard
        // can refuse to route the request to a non-matching browser's
        // bridge (e.g., user is on Safari but only Chrome's extension
        // is connected — would otherwise overlay Chrome's hints on
        // Safari's window).
        let bundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        guard BridgeServer.shared.sendToActive(["cmd": "list_hints"],
                                                expectingBrowserBundleID: bundleID) else {
            print("[browser-provider] no matching extension connection — skipping")
            return nil
        }
        guard let response = await BridgeServer.shared.awaitResponse(
            ofType: "hints",
            timeout: timeout
        ) else {
            print("[browser-provider] timeout waiting for hints (>\(Int(timeout * 1000))ms)")
            return nil
        }
        // Extension reported a fatal-for-this-tab condition — most
        // commonly `content_script_unavailable` when the active tab is
        // a `chrome://` / Web Store / error page. Treat as nil so
        // HintMode.collectAll falls through to OmniParser; otherwise
        // user would see only Dock + menubar hints with no web content
        // hints at all (which is what they hit and got confused by).
        if let err = response["error"] as? String {
            print("[browser-provider] extension reported error=\(err) — falling back to OP")
            return nil
        }
        guard let rawHints = response["hints"] as? [[String: Any]] else {
            print("[browser-provider] response missing 'hints' array: \(response)")
            return nil
        }
        // Even without an explicit error, an empty array on a browser
        // app is suspicious (a real web page should have at least one
        // clickable). Could be a blank page or a still-loading SPA;
        // either way the user gets a better experience by routing to
        // OP than by seeing empty browser hints + no content fallback.
        if rawHints.isEmpty {
            print("[browser-provider] empty hint array — falling back to OP")
            return nil
        }
        let hints = rawHints.compactMap { Hint(rawDict: $0) }
        print("[browser-provider] received \(hints.count) hints from extension")
        return hints
    }
}

private extension BrowserProvider.Hint {
    /// Parse one element of the `hints` array as produced by
    /// `detector.js`. Defensive: any missing field → drop the hint
    /// instead of crashing on a malformed payload.
    init?(rawDict: [String: Any]) {
        guard let rectDict = rawDict["rect"] as? [String: Any] else { return nil }
        // detector.js writes rounded integers; both `Int` and `Double`
        // cast paths are accepted to survive future JSON tweaks.
        func num(_ key: String) -> CGFloat? {
            if let d = rectDict[key] as? Double { return CGFloat(d) }
            if let i = rectDict[key] as? Int    { return CGFloat(i) }
            return nil
        }
        guard let x = num("x"), let y = num("y"),
              let w = num("w"), let h = num("h"),
              w > 0, h > 0 else { return nil }
        self.rect = CGRect(x: x, y: y, width: w, height: h)
        self.tag = (rawDict["tag"] as? String) ?? ""
        self.text = (rawDict["text"] as? String) ?? ""
    }
}
