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
    /// the (possibly empty) list of hints — **the extension's answer
    /// is authoritative for browser apps**.
    ///
    /// Design decision: once we route to the browser branch, no OP
    /// fallback. Cases:
    ///   - extension not connected / bundleID mismatch / timeout:
    ///     returns []. User sees 0 web hints. They get Dock + menubar
    ///     hints only.
    ///   - extension returns `error: content_script_unavailable`
    ///     (active tab is `chrome://` / Web Store / etc. — content
    ///     scripts can't inject there): returns []. Same outcome.
    ///   - extension returns empty hint list (blank tab, fully-OCR-
    ///     resistant page, etc.): returns []. Accept it.
    ///   - extension returns N hints: returns them.
    ///
    /// Rationale: keeping the two paths decoupled is cleaner than
    /// mixing OCR-based hints with DOM-based hints on the same page —
    /// users learn one mental model per app (browser apps = DOM
    /// truth; non-browser apps = AX/OP).
    ///
    /// - parameter timeout: how long to wait. 400ms is generous;
    ///   P2 stage A measured ~35ms on GitHub front page.
    static func fetchHints(timeout: TimeInterval = 0.4) async -> [Hint] {
        let bundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        // sendToActive returns false if extension isn't connected OR
        // is connected but for a different browser than the frontmost.
        // In either case, no extension to ask → accept 0 hints.
        guard BridgeServer.shared.sendToActive(["cmd": "list_hints"],
                                                expectingBrowserBundleID: bundleID) else {
            print("[browser-provider] no matching extension connection — 0 hints")
            return []
        }
        guard let response = await BridgeServer.shared.awaitResponse(
            ofType: "hints",
            timeout: timeout
        ) else {
            print("[browser-provider] timeout waiting for hints (>\(Int(timeout * 1000))ms) — 0 hints")
            return []
        }
        if let err = response["error"] as? String {
            print("[browser-provider] extension reported error=\(err) — accepting 0 hints")
            return []
        }
        guard let rawHints = response["hints"] as? [[String: Any]] else {
            print("[browser-provider] malformed response (no 'hints' array) — 0 hints")
            return []
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
