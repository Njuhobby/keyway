import Cocoa
import ApplicationServices

/// Finds scrollable regions in the focused window via AX.
///
/// Scroll containers are structural (`AXScrollArea` for native
/// NSScrollViews, `AXWebArea` for web content) and AX-exposed even in
/// apps whose *content* AX is poor (WeChat's chat bubbles are
/// invisible to AX, but the message NSScrollView is an AXScrollArea).
/// So scroll-area detection always uses AX, independent of whether the
/// app routes to OmniParser for clickable elements.
/// See `specs/scroll-mode-design.md` §4.
@MainActor
enum ScrollAreaDetector {
    struct Area {
        let rect: CGRect   // screen-space, top-left origin, points
    }

    /// Roles we treat as scrollable regions.
    private static let scrollRoles: Set<String> = ["AXScrollArea", "AXWebArea"]

    /// BFS depth cap. Scroll containers live within the first several
    /// levels; going deeper risks walking huge content subtrees.
    private static let maxDepth = 6
    /// Ignore scroll areas smaller than this (px) — slivers / decorative.
    private static let minSide: CGFloat = 40

    /// Detect scrollable areas in the focused window. Empty if the app
    /// exposes none (zero-AX Electron / games) — caller falls back to
    /// window center (and, eventually, keyboard mouse panning).
    static func detect() -> [Area] {
        guard let (app, _) = FocusedApp.current(),
              let window = focusedWindow(of: app)
        else { return [] }
        // (Tried AXManualAccessibility to force-enable Chromium/Electron
        // a11y here — apps with the tree off didn't respond. Removed.)

        var out: [Area] = []
        var seenRoles: [Int: Set<String>] = [:]   // diagnostic: depth → roles
        // BFS frontier of (element, depth).
        var frontier: [(AXUIElement, Int)] = [(window, 0)]
        while !frontier.isEmpty {
            let (node, depth) = frontier.removeFirst()
            if depth > maxDepth { continue }

            let role = stringAttr(node, "AXRole")
            if let role { seenRoles[depth, default: []].insert(role) }
            if let role, scrollRoles.contains(role) {
                let r = rect(of: node)
                let ok = r != nil && r!.width >= minSide && r!.height >= minSide && onScreen(r!)
                if let r, ok {
                    out.append(Area(rect: r))
                } else {
                    Log.debug("[keyway] scroll: \(role) rejected (rect=\(r.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"))")
                }
                // Don't descend into a found scroll area — nested scroll
                // areas are rare and descending walks the (potentially
                // huge) scrollable content. Revisit if we observe a need.
                continue
            }

            if depth < maxDepth, let children = childrenOf(node) {
                for child in children { frontier.append((child, depth + 1)) }
            }
        }

        // Dedup near-identical rects (some apps double-report a scroll
        // area). Keep first occurrence.
        var deduped: [Area] = []
        for a in out where !deduped.contains(where: { nearlyEqual($0.rect, a.rect) }) {
            deduped.append(a)
        }

        // Diagnostic role census — only when we found NOTHING, to tell
        // "app exposes no scroll AX" (zero-AX Electron) from "our BFS
        // depth/filter missed it". Quiet in the normal case.
        if deduped.isEmpty {
            let census = (0...maxDepth).compactMap { d -> String? in
                guard let roles = seenRoles[d], !roles.isEmpty else { return nil }
                return "d\(d)=[\(roles.sorted().joined(separator: ","))]"
            }.joined(separator: " ")
            Log.debug("[keyway] scroll: 0 areas — AX role census: \(census.isEmpty ? "(empty tree)" : census)")
        }
        return deduped
    }

    // MARK: - AX helpers

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &ref) == .success,
           let w = ref { return (w as! AXUIElement) }
        // Fallback to main window.
        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXMainWindow" as CFString, &mainRef) == .success,
           let w = mainRef { return (w as! AXUIElement) }
        return nil
    }

    private static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func childrenOf(_ el: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &ref) == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    private static func rect(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func onScreen(_ rect: CGRect) -> Bool {
        for screen in NSScreen.screens {
            // Convert NSScreen (bottom-left) to AX (top-left) coords.
            guard let primary = NSScreen.screens.first else { continue }
            let f = screen.frame
            let axRect = CGRect(x: f.minX, y: primary.frame.height - f.maxY,
                                width: f.width, height: f.height)
            if axRect.intersects(rect) { return true }
        }
        return false
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect, tol: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
            && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }
}
