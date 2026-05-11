import Cocoa
import ApplicationServices

struct HintTarget {
    let label: String
    let element: AXUIElement
    let rect: CGRect       // AX screen-space (top-left origin)
    let role: String       // AXButton / AXMenuItem / AXDockItem / ...
}

enum HintResult {
    case pending
    case committed
    case cancelled
}

enum ClickAction {
    case left      // bare hint letter
    case right     // Shift + hint letter
    case double    // Option + hint letter
}

@MainActor
final class HintMode {
    private var targets: [HintTarget] = []
    private var typed: String = ""
    private var isActiveFlag = false

    static let alphabet: [Character] = ["a","s","d","f","g","h","j","k","l"]

    /// Roles we always treat as clickable, even if AXPress isn't advertised.
    private static let clickableRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXTab",
        "AXDisclosureTriangle",
        "AXDockItem",       // Dock 图标
        "AXMenuExtra",      // 菜单栏右侧 status item
    ]

    /// Subtrees we don't bother recursing into — they rarely contain interactive
    /// children and would explode the walk on apps like Slack or web browsers.
    private static let skipRoles: Set<String> = [
        "AXStaticText",
        "AXImage",
        "AXProgressIndicator",
    ]

    private static let maxDepth = 12
    private static let maxTargets = 200

    var isActive: Bool { isActiveFlag }

    @discardableResult
    func activate() -> Bool {
        let collected = Self.collectAll()
        if collected.focused.isEmpty && collected.dock.isEmpty && collected.menuBarExtras.isEmpty {
            return false
        }

        // Dock gets numeric labels (0, 1, 2, ...).
        let dockLabels = Self.generateNumericLabels(count: collected.dock.count)
        let dockTargets = zip(dockLabels, collected.dock).map { (label, c) in
            HintTarget(label: label, element: c.element, rect: c.rect, role: c.role)
        }

        // Focused app + menu bar extras share the alphabetic label space.
        let nonDockCandidates = collected.focused + collected.menuBarExtras
        let letterLabels = Self.generateLabels(count: nonDockCandidates.count)
        let nonDockTargets = zip(letterLabels, nonDockCandidates).map { (label, c) in
            HintTarget(label: label, element: c.element, rect: c.rect, role: c.role)
        }

        targets = dockTargets + nonDockTargets
        typed = ""
        isActiveFlag = true
        HintOverlay.shared.show(targets: targets, typed: "")
        // HUD is owned by VimSession; we no longer touch it from here.
        print("[mouseless] hint: \(targets.count) targets (focused: \(collected.focused.count), dock: \(collected.dock.count), extras: \(collected.menuBarExtras.count))")
        return true
    }

    func deactivate() {
        targets = []
        typed = ""
        isActiveFlag = false
        HintOverlay.shared.hide()
    }

    func handle(char: Character, action: ClickAction = .left) -> HintResult {
        let next = typed + String(char)
        let matches = targets.filter { $0.label.hasPrefix(next) }
        if matches.isEmpty {
            deactivate()
            return .cancelled
        }
        if matches.count == 1 && matches[0].label == next {
            commit(target: matches[0], action: action)
            deactivate()
            return .committed
        }
        typed = next
        HintOverlay.shared.show(targets: targets, typed: typed)
        return .pending
    }

    private func commit(target: HintTarget, action: ClickAction) {
        let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
        switch action {
        case .left:
            // Prefer AXPress (semantic click) — works even if the element
            // is occluded or off-screen. Fall back to a synthetic click.
            let result = AXUIElementPerformAction(target.element, "AXPress" as CFString)
            if result != .success {
                Self.synthesizeClick(at: center, button: .left, count: 1)
            }
        case .right:
            // AXShowMenu opens the right-click menu. Some apps don't expose
            // it on every element, so fall back to a synthetic right click.
            let result = AXUIElementPerformAction(target.element, "AXShowMenu" as CFString)
            if result != .success {
                Self.synthesizeClick(at: center, button: .right, count: 1)
            }
        case .double:
            // No standard AX action for double-click, always synthesize.
            Self.synthesizeClick(at: center, button: .left, count: 2)
        }
    }

    // MARK: - AX collection

    private struct ElementCandidate {
        let element: AXUIElement
        let rect: CGRect
        let role: String
    }

    /// Result of one collection pass — split by source so we can label them
    /// differently (Dock = numeric, everything else = alphabetic).
    private struct CollectedElements {
        let focused: [ElementCandidate]
        let dock: [ElementCandidate]
        let menuBarExtras: [ElementCandidate]
    }

    private static func collectAll() -> CollectedElements {
        let screenSpan = Self.totalScreenSpan()

        // 1. Focused app (the existing behavior).
        let t0 = Date()
        var focusedOut: [ElementCandidate] = []
        var focusedPID: pid_t = 0
        if let (focusedApp, pid) = focusedApplication() {
            focusedPID = pid
            walk(element: focusedApp, depth: 0, into: &focusedOut, screenSpan: screenSpan)
        }
        let t1 = Date()

        // 2. Dock — always scan, regardless of focus.
        var dockOut: [ElementCandidate] = []
        if let dock = applicationElement(forBundleID: "com.apple.dock") {
            walk(element: dock, depth: 0, into: &dockOut, screenSpan: screenSpan)
        }
        let t2 = Date()

        // 3. Menu bar extras — temporarily disabled to measure cost.
        let extrasOut: [ElementCandidate] = []

        print(String(format: "[mouseless] collect timings: focused=%.0fms dock=%.0fms",
                     t1.timeIntervalSince(t0) * 1000,
                     t2.timeIntervalSince(t1) * 1000))
        _ = focusedPID

        return CollectedElements(focused: focusedOut, dock: dockOut, menuBarExtras: extrasOut)
    }

    private static func focusedApplication() -> (element: AXUIElement, pid: pid_t)? {
        let sys = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, "AXFocusedApplication" as CFString, &ref) == .success,
              let app = ref else { return nil }
        let element = app as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return (element, pid)
    }

    private static func applicationElement(forBundleID bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Debug helper: print AX tree role + bounds + actions, up to maxDepth levels.
    private static func debugDumpAXTree(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let pad = String(repeating: "  ", count: depth)
        let role = roleOf(element) ?? "?"
        let rect = boundsOf(element).map { "\($0)" } ?? "nil"
        var actionsRef: CFArray?
        var actions = "?"
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let names = actionsRef as? [String] {
            actions = names.joined(separator: ",")
        }
        print("\(pad)[\(role)] rect=\(rect) actions=[\(actions)]")

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                debugDumpAXTree(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    private static func walk(
        element: AXUIElement,
        depth: Int,
        into out: inout [ElementCandidate],
        screenSpan: CGRect?
    ) {
        guard depth < maxDepth else { return }
        guard out.count < maxTargets else { return }

        let role = roleOf(element) ?? ""
        if skipRoles.contains(role) { return }

        if isClickable(element, role: role), enabled(element),
           let rect = boundsOf(element),
           rect.width >= 8, rect.height >= 8,   // skip invisible micro-elements
           hasMeaningfulLabel(element, role: role),
           onScreen(rect, screenSpan: screenSpan) {
            out.append(ElementCandidate(element: element, rect: rect, role: role))
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                walk(element: child, depth: depth + 1, into: &out, screenSpan: screenSpan)
            }
        }
    }

    private static func isClickable(_ element: AXUIElement, role: String) -> Bool {
        if clickableRoles.contains(role) { return true }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success,
           let names = actions as? [String], names.contains("AXPress") {
            return true
        }
        return false
    }

    /// Skip clickable elements that have NO identifying info — empty title,
    /// description, help, value, and no subrole. These are usually "phantom"
    /// elements that AX reports but the app never actually renders. They
    /// produce hints in empty parts of the screen.
    /// Dock items are exempted because the Dock divider / recents indicator
    /// can have empty titles but still be valid.
    private static func hasMeaningfulLabel(_ element: AXUIElement, role: String) -> Bool {
        if role == "AXDockItem" || role == "AXMenuBarItem" || role == "AXMenuExtra" {
            return true   // these are inherently identifiable by position/role
        }
        for attr in ["AXTitle", "AXDescription", "AXHelp", "AXValue", "AXSubrole"] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let s = ref as? String, !s.isEmpty {
                return true
            }
        }
        return false
    }

    private static func enabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEnabled" as CFString, &ref) == .success,
           let n = ref as? Bool {
            return n
        }
        return true
    }

    private static func roleOf(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    private static func boundsOf(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
            let p = posRef, let s = sizeRef
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(p as! AXValue, .cgPoint, &origin),
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Union of all screens, in AX (top-left origin) coordinates. NSScreen uses
    /// bottom-left, so we flip Y around the primary screen height.
    private static func totalScreenSpan() -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryH = primary.frame.height
        var union: CGRect = .null
        for screen in NSScreen.screens {
            let f = screen.frame
            let axRect = CGRect(
                x: f.minX,
                y: primaryH - f.maxY,
                width: f.width,
                height: f.height
            )
            union = union.isNull ? axRect : union.union(axRect)
        }
        return union.isNull ? nil : union
    }

    private static func onScreen(_ rect: CGRect, screenSpan: CGRect?) -> Bool {
        guard let span = screenSpan else { return true }
        return rect.intersects(span)
    }

    private static func generateLabels(count: Int) -> [String] {
        var out: [String] = []
        out.reserveCapacity(count)
        // Single-char labels when there are few elements — faster to commit.
        if count <= alphabet.count {
            for ch in alphabet.prefix(count) {
                out.append(String(ch))
            }
            return out
        }
        for first in alphabet {
            for second in alphabet {
                out.append("\(first)\(second)")
                if out.count == count { return out }
            }
        }
        return out
    }

    /// Numeric labels for Dock items: "0", "1", ... "9", then "00", "01", ...
    /// to avoid prefix collisions.
    private static func generateNumericLabels(count: Int) -> [String] {
        let digits: [Character] = ["0","1","2","3","4","5","6","7","8","9"]
        var out: [String] = []
        out.reserveCapacity(count)
        if count <= digits.count {
            for ch in digits.prefix(count) {
                out.append(String(ch))
            }
            return out
        }
        for first in digits {
            for second in digits {
                out.append("\(first)\(second)")
                if out.count == count { return out }
            }
        }
        return out
    }

    // MARK: - Synthesized events

    /// Synthesize one or more mouse clicks at `point`. `count` lets us send
    /// double-clicks (the OS recognizes the click via the click-state field
    /// being 1, then 2 for the second pair).
    private static func synthesizeClick(at point: CGPoint,
                                        button: CGMouseButton,
                                        count: Int) {
        let src = CGEventSource(stateID: .privateState)
        let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp

        for clickIdx in 1...count {
            guard
                let down = CGEvent(mouseEventSource: src, mouseType: downType,
                                   mouseCursorPosition: point, mouseButton: button),
                let up = CGEvent(mouseEventSource: src, mouseType: upType,
                                 mouseCursorPosition: point, mouseButton: button)
            else { return }
            for ev in [down, up] {
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickIdx))
                ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
                ev.post(tap: .cghidEventTap)
            }
        }
    }
}
