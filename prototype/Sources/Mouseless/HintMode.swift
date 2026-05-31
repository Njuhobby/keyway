import Cocoa
import ApplicationServices

/// Provenance of a hint target — drives commit-time behavior that
/// can't be derived from rect/role alone:
///
/// - `.ax`: target came from an AX walk. Carries the `AXUIElement`
///   ref + (optionally) the `AXWindow` it belongs to. Cache
///   invalidation on commit uses the window ref; click semantics
///   are identical to the `.omni` case (both synthesize a mouse
///   event at the rect center — AX actions were dropped earlier).
///
/// - `.omni`: target came from the OmniParser visual path. No AX
///   element, no window — purely a screen-space rect + the
///   detector's confidence. Cache doesn't apply. See
///   `omniparser-fallback-design.md` §4.2.
enum HintSource {
    case ax(element: AXUIElement, sourceWindow: AXUIElement?)
    case omni(confidence: Float)
}

struct HintTarget {
    let label: String
    let rect: CGRect       // AX screen-space (top-left origin)
    let role: String       // AXButton / AXMenuItem / AXDockItem / "AXOmni" for OP
    let source: HintSource
}

enum HintResult {
    case pending    // 前缀匹配多个 hint，等更多字符（typed 已更新）
    case committed  // 唯一匹配，已点击
    case ignored    // 不匹配任何 hint 前缀：误按，吞掉不退出（typed 不变）
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

    // h/j/k/l are the unified cursor-move keys (vim hjkl) in TAP *and*
    // SCROLL, so they can't be hint labels — a bare j would be ambiguous
    // (move? or hint?). Everything else ergonomic is fair game.
    //
    // 17 letters → 2-char labels cover 17² = 289 targets, past
    // `maxTargets` (200), so a scan **never needs 3-char labels** (the
    // 3-char tier in `generateLabels` is now effectively dead). Bigger
    // pool also means more targets get fast 1-char labels.
    //
    // Front-loaded by typing comfort: left home row (a s d f g) first,
    // then the strong inner/right keys. 1-char labels use `prefix()` and
    // short labels commit fastest, so the easiest keys must come first.
    // `v` is at the tail — it's only available because DRAG mode moved
    // from bare `v` to the Caps Lock + v chord, freeing it up; bottom-
    // row left index is fine but not as quick as home row.
    static let alphabet: [Character] = [
        "a","s","d","f","g","e","r","u","i","o","p","w","t","n","m","c","v",
    ]

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

    /// Roles whose **subtrees** we don't recurse into — they rarely
    /// contain interactive children and would explode the walk on apps
    /// like Slack or web browsers. We still consider the element ITSELF
    /// as a candidate first (e.g. Finder desktop icons are `AXImage`
    /// with `AXTitle` = filename and are clickable via `AXPress`).
    private static let skipRoles: Set<String> = [
        "AXStaticText",
        "AXImage",
        "AXProgressIndicator",
    ]

    private static let maxDepth = 12
    private static let maxTargets = 200

    /// Attributes we read for every walked element. We fetch them in ONE
    /// `AXUIElementCopyMultipleAttributeValues` call per element instead of
    /// 9 separate `AXUIElementCopyAttributeValue` calls — for an AX tree
    /// with hundreds of nodes (e.g. WeChat, Slack) that's the difference
    /// between hundreds and thousands of cross-process IPC round-trips.
    nonisolated private static let batchAttrNames: [String] = [
        "AXRole",         // 0
        "AXEnabled",      // 1
        "AXPosition",     // 2
        "AXSize",         // 3
        "AXTitle",        // 4
        "AXDescription",  // 5
        "AXHelp",         // 6
        "AXValue",        // 7
        "AXSubrole",      // 8
        "AXChildren",     // 9
    ]
    nonisolated(unsafe) private static let batchAttrsCF: CFArray = batchAttrNames as CFArray

    var isActive: Bool { isActiveFlag }

    @discardableResult
    func activate(isolateApp: Bool = false) async -> Bool {
        let collected = await Self.collectAll(isolateApp: isolateApp)
        if collected.focused.isEmpty
            && collected.focusedOmni.isEmpty
            && collected.dock.isEmpty
            && collected.menuBarExtras.isEmpty {
            return false
        }

        // Dock gets numeric labels (0, 1, 2, ...).
        let dockLabels = Self.generateNumericLabels(count: collected.dock.count)
        let dockTargets = zip(dockLabels, collected.dock).map { (label, c) in
            HintTarget(label: label, rect: c.rect, role: c.role,
                       source: .ax(element: c.element, sourceWindow: c.sourceWindow))
        }

        // Focused (AX + OP) and menu bar extras share the alphabetic label
        // pool. Order: AX-windows → OP candidates → AX menubar/extras —
        // arbitrary but deterministic so labels stay stable across rescans
        // within the same content.
        let totalLetters = collected.focused.count
                         + collected.focusedOmni.count
                         + collected.menuBarExtras.count
        let letterLabels = Self.generateLabels(count: totalLetters)
        var nonDockTargets: [HintTarget] = []
        nonDockTargets.reserveCapacity(totalLetters)
        var idx = 0
        for c in collected.focused {
            nonDockTargets.append(HintTarget(
                label: letterLabels[idx], rect: c.rect, role: c.role,
                source: .ax(element: c.element, sourceWindow: c.sourceWindow)
            ))
            idx += 1
        }
        for c in collected.focusedOmni {
            nonDockTargets.append(HintTarget(
                label: letterLabels[idx], rect: c.rect, role: "AXOmni",
                source: .omni(confidence: c.confidence)
            ))
            idx += 1
        }
        for c in collected.menuBarExtras {
            nonDockTargets.append(HintTarget(
                label: letterLabels[idx], rect: c.rect, role: c.role,
                source: .ax(element: c.element, sourceWindow: c.sourceWindow)
            ))
            idx += 1
        }

        targets = dockTargets + nonDockTargets
        typed = ""
        isActiveFlag = true
        HintOverlay.shared.show(targets: targets, typed: "")
        print("[mouseless] hint: \(targets.count) targets (focusedAX: \(collected.focused.count), focusedOP: \(collected.focusedOmni.count), dock: \(collected.dock.count), extras: \(collected.menuBarExtras.count))")
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
            // Pressed a key that matches no hint prefix — just a misfire.
            // Swallow it: stay in TAP, keep the previous valid `typed`
            // (the bad char isn't appended). User exits with Esc, not by
            // fat-fingering a wrong key.
            return .ignored
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

    /// Undo the last typed hint character. No-op when nothing's typed.
    func backspace() {
        guard !typed.isEmpty else { return }
        typed.removeLast()
        HintOverlay.shared.show(targets: targets, typed: typed)
    }

    private func commit(target: HintTarget, action: ClickAction) {
        // We deliberately bypass AXPress / AXShowMenu / AXOpen and always
        // synthesize a mouse event. AX **metadata** is reliable — that's
        // how we found the target and put a hint on it. AX **actions**
        // are not: many controls expose AXPress in their action list but
        // the handler is a no-op or has unexpected semantics. Synth
        // click is the more predictable primitive — it behaves exactly
        // like a real mouse click, which is the user's mental model.
        //
        // Click point selection differs by source:
        //   - AX target: rect center. AX rects are tight element bounds,
        //     center is always inside the click handler.
        //   - OP target: OCR-refined point. OP boxes may have padding /
        //     border / hidden hit-test boundaries — center is often
        //     fine but sometimes misses (see omniparser-fallback-design
        //     §4.6 for the 5 failure modes). OCR finds text inside the
        //     box; the text's center is almost always inside the real
        //     click handler. Containment-aware: filters out text that
        //     belongs to OP boxes contained within this one.
        switch target.source {
        case .ax:
            let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
            MouseSynth.click(at: center, button: buttonForAction(action),
                             count: countForAction(action))
        case .omni:
            // OCR refiner needs to re-screencap + OCR (~60-90ms total).
            // Dispatch as a Task so the keyboard event tap callback can
            // return synchronously. The hint UI is already going to
            // deactivate via the caller; user perceives the click 60-90ms
            // after pressing the hint key (acceptable — typing rhythm
            // covers this).
            let innerBoxes: [CGRect] = self.targets.compactMap { other in
                guard !targetsAreEqual(other, target),
                      case .omni = other.source,
                      target.rect.contains(other.rect)
                else { return nil }
                return other.rect
            }
            let boxRect = target.rect
            Task { @MainActor in
                let clickPoint = await OCRRefiner.refine(
                    boxScreenRect: boxRect,
                    innerBoxes: innerBoxes
                )
                MouseSynth.click(at: clickPoint, button: buttonForAction(action),
                                 count: countForAction(action))
            }
        }

        // The click may have changed the source window's contents (list
        // selection, disclosure, pane reload, ...). Mark it dirty so the
        // next sticky rescan walks this window fresh while reusing the
        // cache for untouched sibling windows. nil for dock/menu-extra/
        // menu-bar items — they don't belong to any AXWindow. OP-sourced
        // targets have no AXWindow either — the cache is AX-only.
        if case .ax(_, let window?) = target.source {
            HintWindowCache.shared.markDirty(window: window)
        }
    }

    private func buttonForAction(_ action: ClickAction) -> CGMouseButton {
        switch action {
        case .left, .double: return .left
        case .right: return .right
        }
    }

    private func countForAction(_ action: ClickAction) -> Int {
        switch action {
        case .left, .right: return 1
        case .double: return 2
        }
    }

    /// HintTarget identity for "is this the same target?" — by label
    /// since labels are uniquely assigned per session.
    private func targetsAreEqual(_ a: HintTarget, _ b: HintTarget) -> Bool {
        return a.label == b.label
    }

    // MARK: - AX collection

    // `@unchecked Sendable` because `AXUIElement` is a CF type (thread-
    // safe, refcounted), but Swift can't see that automatically. We
    // need to pass collected candidates across the concurrent extras
    // pass.
    private struct ElementCandidate: @unchecked Sendable {
        let element: AXUIElement
        let rect: CGRect
        let role: String
        let sourceWindow: AXUIElement?   // nil for dock / menu extras / menu bar
    }

    /// Result of one collection pass — split by source so we can label them
    /// differently (Dock = numeric, everything else = alphabetic) and route
    /// click semantics by `HintSource`.
    ///
    /// Invariant: `focused` (AX-sourced) and `focusedOmni` (OP-sourced) are
    /// **mutually exclusive for window-level content** within a single
    /// scan — only one path runs per app (`AppRegistry.shouldUseAXForFocused`).
    /// `focused` may still include AX menu bar items even on the OP route
    /// because focused-app AXMenuBar is an always-good AX source (§4.2).
    private struct CollectedElements {
        let focused: [ElementCandidate]                       // AX (windows + menu bar)
        let focusedOmni: [OmniParserPath.OmniCandidate]       // OP (default path only)
        let dock: [ElementCandidate]
        let menuBarExtras: [ElementCandidate]
    }

    /// One element's attributes, fetched in a single batched IPC call.
    /// `@unchecked Sendable` because the CF types inside are thread-safe
    /// but Swift can't see that.
    private struct BatchedAttrs: @unchecked Sendable {
        let role: String?
        let enabled: Bool
        let rect: CGRect?
        let title: String?
        let description: String?
        let help: String?
        let value: String?
        let subrole: String?
        let children: [AXUIElement]
    }

    private static func collectAll(isolateApp: Bool = false) async -> CollectedElements {
        let screenSpan = Self.totalScreenSpan()

        // 1. Focused app. Two sub-sources:
        //   (a) Window subtree — routed by AppRegistry. Whitelisted apps
        //       run the AX walk (per-window cache + walk + recurse). Others
        //       go to OmniParser via `OmniParserPath.collect()` (P4 stub —
        //       returns [] until P5 wires real screencap + inference).
        //   (b) Focused app's AXMenuBar — always AX-walked regardless of
        //       routing. It's an always-good AX source (AppKit/SwiftUI
        //       renders it natively) and OP can't see the menu bar
        //       because it's outside the focused window's pixel area.
        let t0 = Date()
        var focusedOut: [ElementCandidate] = []
        var focusedOmniOut: [OmniParserPath.OmniCandidate] = []
        var focusedIPC = 0
        var cacheHits = 0
        var routeLabel = "no-app"
        if let (focusedApp, focusedPID) = focusedApplication() {
            // focusedApplication() now resolves via NSWorkspace (no AX
            // round-trip), so this isn't an IPC — but keep counting it
            // for log continuity with earlier measurements.
            focusedIPC += 1

            let bundleID = NSRunningApplication(processIdentifier: focusedPID)?.bundleIdentifier
            let useAX = bundleID.map { AppRegistry.shouldUseAXForFocused(bundleID: $0) } ?? false
            routeLabel = useAX ? "AX(whitelist)" : "OP(default)"

            if useAX {
                // Whitelist path: AX walk the focused app's **focused
                // window only**, not all windows. Matches the OP path's
                // scope (it only captures the focused window) and stops
                // us from hinting background windows the user can't see
                // — which inflated candidate counts on apps like Finder
                // where users routinely have multiple windows open.
                // Falls back to AXMainWindow then AXWindows[0] for apps
                // that don't set a focused window after activation
                // (rare for whitelist apps, but cheap to handle).
                HintWindowCache.shared.syncFocusedApp(pid: focusedPID)

                focusedIPC += 1
                var winRef: CFTypeRef?
                var window: AXUIElement? = nil
                if AXUIElementCopyAttributeValue(focusedApp, "AXFocusedWindow" as CFString,
                                                 &winRef) == .success,
                   let raw = winRef {
                    window = (raw as! AXUIElement)
                } else {
                    focusedIPC += 1
                    var mainRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(focusedApp, "AXMainWindow" as CFString,
                                                     &mainRef) == .success,
                       let raw = mainRef {
                        window = (raw as! AXUIElement)
                    }
                }

                let windows: [AXUIElement] = window.map { [$0] } ?? []
                HintWindowCache.shared.pruneTo(currentWindows: windows)

                for window in windows {
                    if let reused = HintWindowCache.shared.reuse(window: window,
                                                                 ipcCount: &focusedIPC) {
                        cacheHits += 1
                        for r in reused {
                            focusedOut.append(ElementCandidate(
                                element: r.element, rect: r.rect, role: r.role,
                                sourceWindow: window))
                        }
                    } else {
                        var fresh: [ElementCandidate] = []
                        walk(element: window, depth: 0, into: &fresh,
                             screenSpan: screenSpan, windowBounds: nil,
                             ipcCount: &focusedIPC,
                             sourceWindow: window)
                        let stored = fresh.map {
                            HintWindowCache.StoredTarget(element: $0.element,
                                                         rect: $0.rect, role: $0.role)
                        }
                        HintWindowCache.shared.store(window: window, targets: stored,
                                                     ipcCount: &focusedIPC)
                        focusedOut.append(contentsOf: fresh)
                    }
                }
            } else {
                // Default path: skip the focused-app window AX walk,
                // call OmniParser visual path instead. P4 stub returns
                // []; real implementation in P5/P6.
                focusedOmniOut = await OmniParserPath.collect(isolateApp: isolateApp)
                // No cache to populate — OP candidates are ephemeral.
            }

            // Focused app's AXMenuBar — always walked regardless of route.
            // Specialized walk that short-circuits the (overwhelmingly
            // common) "no menu dropdown open" case — saves ~40 IPCs per
            // scan on a typical ~10-item menu bar.
            focusedIPC += 1
            var menubarRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedApp, "AXMenuBar" as CFString,
                                             &menubarRef) == .success,
               let menubarRaw = menubarRef {
                let menubar = menubarRaw as! AXUIElement
                walkMenuBar(menubar, into: &focusedOut,
                            screenSpan: screenSpan, ipcCount: &focusedIPC)
            }
        }
        let t1 = Date()

        // 2. Dock — always scan, regardless of focus. Not window-cached
        // (dock changes are rare and the walk is already ~5ms).
        var dockOut: [ElementCandidate] = []
        var dockIPC = 0
        if let dock = applicationElement(forBundleID: "com.apple.dock") {
            walk(element: dock, depth: 0, into: &dockOut,
                 screenSpan: screenSpan, windowBounds: nil,
                 ipcCount: &dockIPC,
                 sourceWindow: nil)
        }
        let t2 = Date()

        // 3. Menu bar extras. The hard work — figuring out *which*
        // PIDs actually own menu extras — is done out-of-band by
        // `MenuExtraCache`: it scans every running app once at launch
        // (in the background) and stays current via NSWorkspace
        // launch/terminate notifications. Here we just iterate the
        // ~5-10 PIDs the cache hands us and pull their current extras.
        // No CGWindowList, no per-trigger app enumeration.
        var extrasOut: [ElementCandidate] = []
        for pid in MenuExtraCache.shared.currentPIDs() {
            let appElement = AXUIElementCreateApplication(pid)
            collectDirectMenuExtras(from: appElement,
                                    into: &extrasOut,
                                    screenSpan: screenSpan)
        }
        let t3 = Date()

        print(String(format: "[mouseless] collect timings: focused=%.0fms [%@] (%d IPC, %d window cache hit, ax=%d op=%d) dock=%.0fms (%d IPC) extras=%.0fms",
                     t1.timeIntervalSince(t0) * 1000, routeLabel, focusedIPC, cacheHits,
                     focusedOut.count, focusedOmniOut.count,
                     t2.timeIntervalSince(t1) * 1000, dockIPC,
                     t3.timeIntervalSince(t2) * 1000))

        return CollectedElements(focused: focusedOut, focusedOmni: focusedOmniOut,
                                 dock: dockOut, menuBarExtras: extrasOut)
    }

    private static func focusedApplication() -> (element: AXUIElement, pid: pid_t)? {
        // Via NSWorkspace, not AXFocusedApplication — the latter is
        // flaky on Electron apps. See FocusedApp.swift.
        return FocusedApp.current()
    }

    private static func applicationElement(forBundleID bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Shallow walk for menu bar extras. Modern macOS exposes them via
    /// the standard `AXExtrasMenuBar` attribute on the owning app (the
    /// children carry role `AXMenuBarItem` for ControlCenter, or
    /// `AXMenuExtra` for older / non-standard agents — accept both).
    /// Legacy fallback: some apps just put `AXMenuExtra` as a direct
    /// child of the app root.
    ///
    /// `nonisolated` so we can fan this out across a concurrent queue —
    /// it only does AX IPC and touches no main-actor state.
    nonisolated private static func collectDirectMenuExtras(
        from app: AXUIElement,
        into out: inout [ElementCandidate],
        screenSpan: CGRect?
    ) {
        var extrasRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
           let extras = extrasRef {
            let bar = extras as! AXUIElement
            var grandRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(bar, "AXChildren" as CFString, &grandRef) == .success,
               let grandchildren = grandRef as? [AXUIElement] {
                for grand in grandchildren {
                    guard let role = roleOf(grand),
                          role == "AXMenuBarItem" || role == "AXMenuExtra"
                    else { continue }
                    appendIfValid(grand, role: role, into: &out, screenSpan: screenSpan)
                }
            }
            // Done — `AXExtrasMenuBar` is the authoritative source.
            return
        }

        // No `AXExtrasMenuBar`. Look for `AXMenuExtra` as a direct child
        // of the root (some agents register their status item that way).
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXChildren" as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children where roleOf(child) == "AXMenuExtra" {
            appendIfValid(child, role: "AXMenuExtra", into: &out, screenSpan: screenSpan)
        }
    }

    nonisolated private static func appendIfValid(
        _ element: AXUIElement,
        role: String,
        into out: inout [ElementCandidate],
        screenSpan: CGRect?
    ) {
        guard enabled(element),
              let rect = boundsOf(element),
              rect.width >= 8, rect.height >= 8,
              onScreen(rect, screenSpan: screenSpan)
        else { return }
        out.append(ElementCandidate(element: element, rect: rect, role: role,
                                    sourceWindow: nil))
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

    /// Specialized walk for the focused app's `AXMenuBar`. The vast
    /// majority of the time, no dropdown is open: the menu bar items are
    /// just sitting there waiting to be clicked, and the `AXMenu` under
    /// each is closed (but still present in the AX tree, hence the
    /// `axMenuIsOpen` probe in the generic walk). Walking the menubar
    /// via `walk()` would `batchFetch` the AXMenu under every item and
    /// do a 3-IPC `axMenuIsOpen` probe each time — ~5 IPCs/item, ~50
    /// for a typical 10-item menu bar. **All of that is wasted in the
    /// closed-menu case.**
    ///
    /// Fast path: one `AXSelectedChildren` read on the AXMenuBar tells
    /// us whether any menu is open. Empty → just `batchFetch` the
    /// items themselves, no descent. ~12 IPCs for the same 10 items.
    ///
    /// Slow path (a menu IS open) falls back to `walk()` so the open
    /// dropdown's `AXMenuItem`s still get hinted.
    private static func walkMenuBar(
        _ menubar: AXUIElement,
        into out: inout [ElementCandidate],
        screenSpan: CGRect?,
        ipcCount: inout Int
    ) {
        ipcCount += 1
        var selectedRef: CFTypeRef?
        let menuIsOpen: Bool = {
            guard AXUIElementCopyAttributeValue(
                    menubar, "AXSelectedChildren" as CFString, &selectedRef
                  ) == .success,
                  let arr = selectedRef as? [AXUIElement], !arr.isEmpty
            else { return false }
            return true
        }()

        if menuIsOpen {
            walk(element: menubar, depth: 0, into: &out,
                 screenSpan: screenSpan, windowBounds: nil,
                 ipcCount: &ipcCount,
                 sourceWindow: nil)
            return
        }

        // No menu open. Emit each AXMenuBarItem without descending —
        // the closed AXMenu under each has nothing visible to hint.
        guard let attrs = batchFetch(menubar, ipcCount: &ipcCount) else { return }
        for item in attrs.children {
            guard out.count < maxTargets else { return }
            guard let itemAttrs = batchFetch(item, ipcCount: &ipcCount) else { continue }
            let role = itemAttrs.role ?? ""

            guard itemAttrs.enabled,
                  let rect = itemAttrs.rect,
                  rect.width >= 8, rect.height >= 8,
                  onScreen(rect, screenSpan: screenSpan),
                  hasMeaningfulLabel(role: role, attrs: itemAttrs),
                  isClickable(item, role: role, ipcCount: &ipcCount)
            else { continue }

            out.append(ElementCandidate(element: item, rect: rect, role: role,
                                        sourceWindow: nil))
        }
    }

    private static func walk(
        element: AXUIElement,
        depth: Int,
        into out: inout [ElementCandidate],
        screenSpan: CGRect?,
        windowBounds: CGRect?,
        ipcCount: inout Int,
        sourceWindow: AXUIElement?
    ) {
        guard depth < maxDepth else { return }
        guard out.count < maxTargets else { return }

        guard let attrs = batchFetch(element, ipcCount: &ipcCount) else { return }
        let role = attrs.role ?? ""

        // At the root of a focused-app window walk, capture this element's
        // rect as the bound for the entire subtree. AX rows that are
        // scrolled outside the window's viewport sometimes still report
        // rects within the global display geometry (just *below* the
        // visible window) — `onScreen` accepts them, but they aren't
        // actually visible to the user and the hint label would land on
        // whatever's underneath (the window behind). Clamping subsequent
        // candidacy to this window's bounds drops those phantom rows.
        // Dock / menu bar / menu extras walks pass `sourceWindow: nil` so
        // they skip this — they don't have a single "window" container.
        let effectiveBounds: CGRect?
        if depth == 0, sourceWindow != nil, windowBounds == nil {
            effectiveBounds = attrs.rect
        } else {
            effectiveBounds = windowBounds
        }

        // Snapshot the candidate count so the source-list `AXRow`
        // fallback at the end of this function can detect "this row
        // contributed nothing" (no clickable descendant). See the
        // comment on that fallback.
        let countAtStart = out.count

        // Candidacy: cheap filters first (everything below comes from the
        // batched attrs, no extra IPC). `isClickable` for unknown roles
        // requires an extra `AXUIElementCopyActionNames` round-trip, so
        // it goes LAST — by then everything else has already filtered out
        // the bulk of non-candidates.
        if attrs.enabled,
           let rect = attrs.rect,
           rect.width >= 8, rect.height >= 8,
           onScreen(rect, screenSpan: screenSpan),
           withinWindow(rect, bounds: effectiveBounds),
           hasMeaningfulLabel(role: role, attrs: attrs),
           isClickable(element, role: role, ipcCount: &ipcCount) {
            out.append(ElementCandidate(element: element, rect: rect, role: role,
                                        sourceWindow: sourceWindow))
        }

        if skipRoles.contains(role) { return }

        // Closed menubar dropdowns: AppKit leaves the AXMenu and its
        // AXMenuItem children in the AX tree even when not visible,
        // and some descendants (e.g. AXButton inside an AXMenuItem)
        // report stale positions that pass our size/onScreen filters
        // → ghost hints at the menu's last-open coords. Only walk an
        // AXMenu when its parent AXMenuBarItem reports AXSelected=true
        // (menu is currently shown). Dock context menus are handled
        // separately by `x` via AXCancel; their parent is AXDockItem,
        // not AXMenuBarItem, so this check doesn't affect them.
        if role == "AXMenu", !axMenuIsOpen(element, ipcCount: &ipcCount) {
            return
        }

        // Subtree culling: if this container's bounds are reported,
        // non-empty, and don't intersect any screen, nothing inside can
        // possibly be on-screen either — skip the whole subtree. We
        // require non-empty bounds because nil/zero is the "unknown"
        // sentinel from buggy AX implementations (some SwiftUI / web
        // view / Electron containers); culling on those would risk
        // dropping real children.
        if let rect = attrs.rect, !rect.isEmpty, let span = screenSpan,
           !rect.intersects(span) {
            return
        }
        // Same culling against the window bound — drop entire subtrees
        // that AX puts outside this window's viewport (scrolled-off
        // table sections etc.).
        if let rect = attrs.rect, !rect.isEmpty, let bounds = effectiveBounds,
           !rect.intersects(bounds) {
            return
        }

        for child in attrs.children {
            walk(element: child, depth: depth + 1, into: &out,
                 screenSpan: screenSpan, windowBounds: effectiveBounds,
                 ipcCount: &ipcCount, sourceWindow: sourceWindow)
        }

        // Source-list fallback. Apple's NSOutlineView source list
        // (Finder / Mail / Notes / Music / System Settings / Calendar
        // sidebars) makes the **row** the click target: clicking selects
        // it (the app writes `AXSelectedRows`), but the row neither
        // sits in `clickableRoles` nor exposes `AXPress` / `AXOpen`, so
        // the candidacy check above didn't add it. If our walk found
        // **no clickable descendant** inside the row (`out.count`
        // unchanged from before we considered this element), the row is
        // the click target — synth-clicking its center selects the
        // item, which is the user-visible effect they want. If a
        // descendant IS clickable (Finder's *main* list rows have an
        // `AXImage` child with `AXOpen` → the icon was already hinted),
        // we prefer that and skip the row to avoid duplicate hints.
        //
        // Costs nothing extra: no IPC, just a count comparison.
        if role == "AXRow",
           out.count == countAtStart,
           attrs.enabled,
           let rect = attrs.rect,
           rect.width >= 8, rect.height >= 8,
           onScreen(rect, screenSpan: screenSpan),
           withinWindow(rect, bounds: effectiveBounds),
           hasMeaningfulLabel(role: role, attrs: attrs) {
            out.append(ElementCandidate(element: element, rect: rect, role: role,
                                        sourceWindow: sourceWindow))
        }
    }

    /// True if `rect` intersects the source window's bounds (or there's
    /// no window bound to compare against). Used to exclude AX elements
    /// whose reported rect falls outside the visible window viewport —
    /// commonly scrolled-off rows in long sidebars/tables, which AX
    /// still puts in the tree with a "virtual" position below the
    /// viewport.
    nonisolated private static func withinWindow(_ rect: CGRect, bounds: CGRect?) -> Bool {
        guard let bounds = bounds else { return true }
        return rect.intersects(bounds)
    }

    /// Returns true if this AXMenu's parent is an AXMenuBarItem that
    /// is currently selected (i.e. the user has clicked the menubar
    /// item and the dropdown is visible). For any other parent shape
    /// (Dock items, system menus, etc.) returns true unconditionally —
    /// we only have evidence of the ghost-menu problem under
    /// AXMenuBarItem so far, and don't want to over-filter.
    private static func axMenuIsOpen(_ menu: AXUIElement,
                                     ipcCount: inout Int) -> Bool {
        ipcCount += 1
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, "AXParent" as CFString, &parentRef) == .success,
              let raw = parentRef else { return true }
        let parent = raw as! AXUIElement
        ipcCount += 1   // roleOf
        guard roleOf(parent) == "AXMenuBarItem" else { return true }
        ipcCount += 1   // AXSelected
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, "AXSelected" as CFString, &selectedRef) == .success,
              let isSelected = selectedRef as? Bool else { return false }
        return isSelected
    }

    private static func isClickable(_ element: AXUIElement, role: String,
                                    ipcCount: inout Int) -> Bool {
        if clickableRoles.contains(role) { return true }
        ipcCount += 1
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let names = actions as? [String] else { return false }
        // `AXOpen` is what Finder desktop icons (`AXImage`) advertise
        // in place of `AXPress` — accepting it makes them hintable
        // while still keeping decorative images (no actions, or no
        // meaningful label) out.
        return names.contains("AXPress") || names.contains("AXOpen")
    }

    /// Skip clickable elements that have NO identifying info — empty title,
    /// description, help, value, and no subrole. These are usually "phantom"
    /// elements that AX reports but the app never actually renders. They
    /// produce hints in empty parts of the screen.
    /// Dock items are exempted because the Dock divider / recents indicator
    /// can have empty titles but still be valid.
    private static func hasMeaningfulLabel(role: String,
                                           attrs: BatchedAttrs) -> Bool {
        if role == "AXDockItem" || role == "AXMenuBarItem" || role == "AXMenuExtra" {
            return true   // these are inherently identifiable by position/role
        }
        if let s = attrs.title, !s.isEmpty { return true }
        if let s = attrs.description, !s.isEmpty { return true }
        if let s = attrs.help, !s.isEmpty { return true }
        if let s = attrs.value, !s.isEmpty { return true }
        if let s = attrs.subrole, !s.isEmpty { return true }
        return false
    }

    /// Fetch every attribute we care about in ONE IPC round-trip.
    /// Missing/inapplicable attributes come back as `AXValue` of type
    /// `.axError` — we filter those out per slot. Returns `nil` only if
    /// the whole call failed (dead PID, invalid element).
    nonisolated private static func batchFetch(_ element: AXUIElement,
                                               ipcCount: inout Int) -> BatchedAttrs? {
        ipcCount += 1
        var valuesRef: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element, batchAttrsCF,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        )
        guard result == .success,
              let arr = valuesRef as? [AnyObject],
              arr.count == batchAttrNames.count
        else { return nil }

        // Per-slot getter that strips AXError sentinels.
        func slot(_ i: Int) -> AnyObject? {
            let v = arr[i]
            if CFGetTypeID(v) == AXValueGetTypeID() {
                // It's an AXValue — could be a real value (Position/Size)
                // or an error sentinel. Caller will type-check before use.
                let axv = v as! AXValue
                if AXValueGetType(axv) == .axError { return nil }
            }
            return v
        }

        let role = slot(0) as? String
        let enabled = (slot(1) as? Bool) ?? true

        var rect: CGRect? = nil
        if let posObj = slot(2), let sizeObj = slot(3),
           CFGetTypeID(posObj) == AXValueGetTypeID(),
           CFGetTypeID(sizeObj) == AXValueGetTypeID() {
            let posV = posObj as! AXValue
            let sizeV = sizeObj as! AXValue
            if AXValueGetType(posV) == .cgPoint && AXValueGetType(sizeV) == .cgSize {
                var origin = CGPoint.zero
                var size = CGSize.zero
                if AXValueGetValue(posV, .cgPoint, &origin),
                   AXValueGetValue(sizeV, .cgSize, &size) {
                    rect = CGRect(origin: origin, size: size)
                }
            }
        }

        let title = slot(4) as? String
        let description = slot(5) as? String
        let help = slot(6) as? String
        let value = slot(7) as? String
        let subrole = slot(8) as? String
        let children = (slot(9) as? [AXUIElement]) ?? []

        return BatchedAttrs(
            role: role, enabled: enabled, rect: rect,
            title: title, description: description, help: help,
            value: value, subrole: subrole, children: children
        )
    }

    nonisolated private static func enabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEnabled" as CFString, &ref) == .success,
           let n = ref as? Bool {
            return n
        }
        return true
    }

    nonisolated private static func roleOf(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    nonisolated private static func boundsOf(_ element: AXUIElement) -> CGRect? {
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

    nonisolated private static func onScreen(_ rect: CGRect, screenSpan: CGRect?) -> Bool {
        guard let span = screenSpan else { return true }
        return rect.intersects(span)
    }

    private static func generateLabels(count: Int) -> [String] {
        // CRITICAL: all returned labels must be the same length within
        // a single call's output. Mixing lengths creates prefix
        // collisions (e.g. "aa" is a prefix of "aaa"): user types
        // "a a" and the system can't tell if they want to commit "aa"
        // or are still building "aaa". Picking the shortest tier that
        // fits avoids this entirely.
        let n = alphabet.count   // 17
        var out: [String] = []
        out.reserveCapacity(count)

        if count <= n {
            // 1-letter labels — fastest to commit.
            for ch in alphabet.prefix(count) {
                out.append(String(ch))
            }
            return out
        }
        if count <= n * n {
            // 2-letter labels — n² = 289 covers every scan (maxTargets
            // is 200), so this is the tier dense scans land in.
            for first in alphabet {
                for second in alphabet {
                    out.append("\(first)\(second)")
                    if out.count == count { return out }
                }
            }
            return out
        }
        // 3-letter labels — unreachable with n=17 (289 > maxTargets 200),
        // kept only as a safety net if the pool or cap ever change.
        for first in alphabet {
            for second in alphabet {
                for third in alphabet {
                    out.append("\(first)\(second)\(third)")
                    if out.count == count { return out }
                }
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
}
