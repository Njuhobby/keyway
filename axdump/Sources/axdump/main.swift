import Cocoa
import ApplicationServices

// axdump — dump the COMPLETE, UNFILTERED Accessibility tree of a running
// app's window(s) to stdout. Ground-truth tool for Mouseless's AX-coverage
// work: before deciding whether an app can be served by per-app AX
// predicate rules (the element IS in the tree, the hint walker just doesn't
// reach it) or must fall back to OmniParser (the element is genuinely
// ABSENT from the tree), we need to SEE what AX actually exposes. The specs
// disagree on this for apps like Slack — so measure, don't guess.
//
// Unlike Mouseless's HintMode walk, this applies NO filtering: no role
// allow-list, no visibility/size pruning, no depth cap. Every node is
// printed with role / subrole / actions (key signal: AXPress?) / label /
// rect / enabled / identifier, so wrapped-in-AXGroup or action-less-but-
// clickable elements are visible.

let MAX_DEPTH = 60
let MAX_NODES = 50_000

// MARK: - AX helpers

func copyEl(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func copyArray(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return nil }
    return arr
}

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let n = v as? NSNumber else { return nil }
    return n.boolValue
}

func actionNames(_ el: AXUIElement) -> [String] {
    var arr: CFArray?
    guard AXUIElementCopyActionNames(el, &arr) == .success, let names = arr as? [String] else { return [] }
    return names
}

func rectStr(_ el: AXUIElement) -> String {
    var pRef: CFTypeRef?
    var sRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &pRef) == .success,
          AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sRef) == .success,
          let pRef, let sRef else { return "" }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pRef as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sRef as! AXValue, .cgSize, &size) else { return "" }
    return " rect=(\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))×\(Int(size.height)))"
}

func clip(_ s: String, _ n: Int = 80) -> String {
    let oneLine = s.replacingOccurrences(of: "\n", with: "⏎")
    return oneLine.count <= n ? oneLine : String(oneLine.prefix(n)) + "…"
}

func line(_ el: AXUIElement, depth: Int, role: String, actions: [String]) -> String {
    let indent = String(repeating: "  ", count: depth)
    let subrole = str(el, "AXSubrole").map { "[\($0)]" } ?? ""
    let label = [str(el, "AXTitle"), str(el, "AXDescription"), str(el, "AXValue"), str(el, "AXHelp")]
        .compactMap { $0 }.first { !$0.isEmpty }.map { "\"\(clip($0))\"" } ?? ""
    let acts = actions.isEmpty ? "" : " actions=[\(actions.joined(separator: ","))]"
    let enabled = (boolAttr(el, "AXEnabled") == false) ? " en=N" : ""
    let ident = str(el, "AXIdentifier").map { " id=\($0)" } ?? ""
    let selected = (boolAttr(el, "AXSelected") == true) ? " SELECTED" : ""
    return "\(indent)\(role)\(subrole) \(label)\(acts)\(rectStr(el))\(enabled)\(ident)\(selected)\n"
}

// MARK: - "Would Mouseless hint this?" predicate
//
// Mirrors HintMode's AX candidacy + reachability so the dump can MARK the
// nodes Mouseless's CURRENT logic would turn into hint targets (left-margin
// "▶"). The gap between "marked" and "clickable-but-unmarked" is exactly
// the AX-coverage signal we want to study.
//
// KEEP IN SYNC with HintMode.swift: clickableRoles / skipRoles / maxDepth /
// the candidacy check in walk() / hasMeaningfulLabel / onScreen /
// withinWindow / the AXRow source-list fallback. Deliberate
// approximations (noted in the output header): the 169-target cap and the
// menubar-only closed-AXMenu nuance.
let HINT_DEPTH = 12   // HintMode.maxDepth
let clickableRoles: Set<String> = [
    "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTab",
    "AXDisclosureTriangle", "AXDockItem", "AXMenuExtra",
]
let skipRoles: Set<String> = ["AXStaticText", "AXImage", "AXProgressIndicator"]

func totalScreenSpan() -> CGRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    let primaryH = primary.frame.height
    var union = CGRect.null
    for s in NSScreen.screens {
        let f = s.frame
        let ax = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
        union = union.isNull ? ax : union.union(ax)
    }
    return union.isNull ? nil : union
}
let screenSpan = totalScreenSpan()

func rectOf(_ el: AXUIElement) -> CGRect? {
    var pRef: CFTypeRef?; var sRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &pRef) == .success,
          AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sRef) == .success,
          let pRef, let sRef else { return nil }
    var o = CGPoint.zero; var sz = CGSize.zero
    guard AXValueGetValue(pRef as! AXValue, .cgPoint, &o),
          AXValueGetValue(sRef as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: o, size: sz)
}
func enabledAttr(_ el: AXUIElement) -> Bool { boolAttr(el, "AXEnabled") ?? true }
func onScreen(_ r: CGRect) -> Bool { guard let s = screenSpan else { return true }; return r.intersects(s) }
func withinWindow(_ r: CGRect, _ b: CGRect?) -> Bool { guard let b else { return true }; return r.intersects(b) }
func meaningfulLabel(_ role: String, _ el: AXUIElement) -> Bool {
    if role == "AXDockItem" || role == "AXMenuBarItem" || role == "AXMenuExtra" { return true }
    for a in ["AXTitle", "AXDescription", "AXHelp", "AXValue", "AXSubrole"] {
        if let s = str(el, a), !s.isEmpty { return true }
    }
    return false
}
func isClickableHint(_ role: String, _ actions: [String]) -> Bool {
    if clickableRoles.contains(role) { return true }
    return actions.contains("AXPress") || actions.contains("AXOpen")
}
func axMenuIsOpen(_ el: AXUIElement) -> Bool {
    guard let parent = copyEl(el, "AXParent") else { return false }
    return str(parent, "AXRole") == "AXMenuBarItem" && (boolAttr(parent, "AXSelected") == true)
}
func culled(_ rect: CGRect?, _ window: CGRect?) -> Bool {
    guard let r = rect, !r.isEmpty else { return false }
    if let s = screenSpan, !r.intersects(s) { return true }
    if let w = window, !r.intersects(w) { return true }
    return false
}

// MARK: - Walk

struct DumpNode { let depth: Int; let text: String; var isHint: Bool }
var nodes: [DumpNode] = []
var nodeCount = 0
var hintCount = 0
var roleCounts: [String: Int] = [:]
var pressableCount = 0
var truncated = false

/// Append one DumpNode per element. `reachable` tracks whether Mouseless's
/// hint walker would descend this far (ancestor skipRoles / closed AXMenu /
/// subtree culling / depth). Returns the count of hint-marked nodes in this
/// subtree — used by the AXRow source-list fallback (row is a target only
/// when it has no clickable descendant).
@discardableResult
func walk(_ el: AXUIElement, depth: Int, reachable: Bool, windowBounds: CGRect?) -> Int {
    if nodeCount >= MAX_NODES { truncated = true; return 0 }
    nodeCount += 1
    let role = str(el, "AXRole") ?? "?"
    roleCounts[role, default: 0] += 1
    let actions = actionNames(el)
    if actions.contains("AXPress") || actions.contains("AXOpen") { pressableCount += 1 }
    let rect = rectOf(el)

    var selfHint = false
    if reachable, depth < HINT_DEPTH, enabledAttr(el), let r = rect,
       r.width >= 8, r.height >= 8, onScreen(r), withinWindow(r, windowBounds),
       meaningfulLabel(role, el), isClickableHint(role, actions) {
        selfHint = true
    }

    let myIndex = nodes.count
    nodes.append(DumpNode(depth: depth,
                          text: line(el, depth: depth, role: role, actions: actions),
                          isHint: selfHint))
    if selfHint { hintCount += 1 }

    var subtreeHints = selfHint ? 1 : 0
    guard depth < MAX_DEPTH else { return subtreeHints }

    let descend = reachable && (depth + 1 < HINT_DEPTH)
        && !skipRoles.contains(role)
        && !(role == "AXMenu" && !axMenuIsOpen(el))
        && !culled(rect, windowBounds)
    var descendantHints = 0
    for child in copyArray(el, "AXChildren") ?? [] {
        descendantHints += walk(child, depth: depth + 1, reachable: descend, windowBounds: windowBounds)
    }
    subtreeHints += descendantHints

    // AXRow source-list fallback (Finder / Mail / Notes / Music sidebars):
    // the row itself is the click target when no descendant was hinted.
    if role == "AXRow", reachable, depth < HINT_DEPTH, !selfHint, descendantHints == 0,
       enabledAttr(el), let r = rect, r.width >= 8, r.height >= 8,
       onScreen(r), withinWindow(r, windowBounds), meaningfulLabel(role, el) {
        nodes[myIndex].isHint = true
        hintCount += 1
        subtreeHints += 1
    }
    return subtreeHints
}

// MARK: - App resolution

func listRunningApps() {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    FileHandle.standardError.write("Running apps (foreground):\n".data(using: .utf8)!)
    for a in apps {
        let nm = a.localizedName ?? "?"
        let bid = a.bundleIdentifier ?? "?"
        FileHandle.standardError.write("  \(nm)  —  \(bid)\n".data(using: .utf8)!)
    }
}

func findApp(matching query: String) -> NSRunningApplication? {
    let q = query.lowercased()
    let all = NSWorkspace.shared.runningApplications
    let matches = all.filter {
        (($0.localizedName ?? "").lowercased().contains(q)) ||
        (($0.bundleIdentifier ?? "").lowercased().contains(q))
    }
    // Prefer a regular (dock) app over agents when ambiguous.
    return matches.first { $0.activationPolicy == .regular } ?? matches.first
}

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())

// --wake: before dumping, try to WAKE an Electron/Chromium app's a11y tree
// (Chromium builds it lazily, only when an assistive tech is detected).
// Setting AXManualAccessibility (Chromium's flag) + AXEnhancedUserInterface
// (AppKit's "an AT is present") asks the app to populate AX, then we wait a
// beat for the renderer to build it. Compare `axdump X` vs `axdump --wake X`
// to see whether AX can serve an app that's sparse when cold.
let wake = args.contains("--wake")
args.removeAll { $0 == "--wake" }

if args.isEmpty || args.first == "--help" || args.first == "-h" {
    eprint("""
    axdump — dump an app's full Accessibility tree to stdout.

    Usage:
      axdump <name-or-bundle-substring>     dump that running app's window(s)
      axdump --frontmost [seconds]          wait N s (default 3), then dump the
                                            frontmost app (switch to it meanwhile)
      axdump --wake <app>                   set AXManualAccessibility +
                                            AXEnhancedUserInterface first, wait,
                                            then dump (wakes Electron a11y)
      axdump --list                         list running foreground apps
      axdump --help

    Examples:
      axdump Slack > slack.txt
      axdump com.tinyspeck.slackmacgap > slack.txt
      axdump --frontmost 4 > whatever.txt
    """)
    if args.first == "--help" || args.first == "-h" { exit(0) }
    exit(args.isEmpty ? 1 : 0)
}

if args.first == "--list" {
    listRunningApps()
    exit(0)
}

// Accessibility trust is per-process. A freshly-built CLI isn't trusted —
// prompt to add it (System Settings → Privacy & Security → Accessibility).
let trustOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(trustOpts) {
    eprint("""
    [axdump] This binary is NOT trusted for Accessibility — AX queries will
    return nothing. A system prompt should have appeared; otherwise:
      System Settings → Privacy & Security → Accessibility → add:
      \(CommandLine.arguments.first ?? "axdump")
    Then re-run. (The .build path is stable, so you only grant it once.)
    """)
    exit(2)
}

// Resolve the target app.
let target: NSRunningApplication
if args.first == "--frontmost" {
    let delay = args.count > 1 ? (Double(args[1]) ?? 3) : 3
    eprint("[axdump] switch to the target app — dumping frontmost in \(Int(delay))s …")
    Thread.sleep(forTimeInterval: delay)
    guard let front = NSWorkspace.shared.frontmostApplication else {
        eprint("[axdump] no frontmost application"); exit(3)
    }
    target = front
} else {
    guard let app = findApp(matching: args[0]) else {
        eprint("[axdump] no running app matching \"\(args[0])\". Try: axdump --list")
        exit(3)
    }
    target = app
}

let pid = target.processIdentifier
let name = target.localizedName ?? "app"
let bundle = target.bundleIdentifier ?? "unknown"
let appEl = AXUIElementCreateApplication(pid)

if wake {
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    eprint("[axdump] --wake: set AXManualAccessibility + AXEnhancedUserInterface on \(name); waiting 1.5s for the a11y tree to build…")
    Thread.sleep(forTimeInterval: 1.5)
}

// Dump every window (focus state is unreliable for a non-frontmost target,
// so don't rely on AXFocusedWindow — show all windows). Fall back to the
// app element if no windows are exposed.
let windows = copyArray(appEl, "AXWindows") ?? []

var body = ""
func flushNodes() {
    for n in nodes { body += (n.isHint ? "▶ " : "  ") + n.text }
    nodes.removeAll(keepingCapacity: true)
}
if windows.isEmpty {
    eprint("[axdump] \(name): no AXWindows exposed — dumping the application element")
    walk(appEl, depth: 0, reachable: true, windowBounds: nil)
    flushNodes()
} else {
    for (i, w) in windows.enumerated() {
        let title = str(w, "AXTitle").map { " \"\(clip($0))\"" } ?? ""
        body += "\n== window[\(i)]\(title) ==\n"
        walk(w, depth: 0, reachable: true, windowBounds: rectOf(w))
        flushNodes()
    }
}

var header = ""
header += "# AX dump — \(name) (\(bundle), pid \(pid))\(wake ? "  [--wake: a11y woken]" : "")\n"
header += "# windows: \(windows.count)\n"
header += "# nodes: \(nodeCount)\(truncated ? " (TRUNCATED at \(MAX_NODES))" : "")"
header += ", with AXPress/AXOpen: \(pressableCount)\n"
header += "# ▶ Mouseless would hint: \(hintCount)  (mirrors HintMode; grep '^▶')\n"
header += "#   approximations: 169-target cap and closed-AXMenu nuance NOT applied\n"
header += "# roles: " + roleCounts.sorted { $0.value > $1.value }
    .map { "\($0.key)×\($0.value)" }.joined(separator: ", ") + "\n"
header += "# format: <▶|·> <indent><role>[<subrole>] \"label\" actions=[…] rect=(x,y w×h) en=N id=… SELECTED\n"
header += "#         ▶ = Mouseless's current logic would mark this a hint target\n"

print(header + body)
eprint("[axdump] \(name): \(nodeCount) nodes, \(pressableCount) AXPress/AXOpen, \(hintCount) would-be hints")
