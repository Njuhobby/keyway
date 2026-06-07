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

// MARK: - Walk

var nodeCount = 0
var roleCounts: [String: Int] = [:]
var pressableCount = 0
var truncated = false

func walk(_ el: AXUIElement, depth: Int, into out: inout String) {
    if nodeCount >= MAX_NODES { truncated = true; return }
    nodeCount += 1
    let role = str(el, "AXRole") ?? "?"
    roleCounts[role, default: 0] += 1
    let actions = actionNames(el)
    if actions.contains("AXPress") || actions.contains("AXOpen") { pressableCount += 1 }
    out += line(el, depth: depth, role: role, actions: actions)
    guard depth < MAX_DEPTH else { return }
    for child in copyArray(el, "AXChildren") ?? [] {
        walk(child, depth: depth + 1, into: &out)
    }
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

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args.first == "--help" || args.first == "-h" {
    eprint("""
    axdump — dump an app's full Accessibility tree to stdout.

    Usage:
      axdump <name-or-bundle-substring>     dump that running app's window(s)
      axdump --frontmost [seconds]          wait N s (default 3), then dump the
                                            frontmost app (switch to it meanwhile)
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

// Dump every window (focus state is unreliable for a non-frontmost target,
// so don't rely on AXFocusedWindow — show all windows). Fall back to the
// app element if no windows are exposed.
let windows = copyArray(appEl, "AXWindows") ?? []

var body = ""
if windows.isEmpty {
    eprint("[axdump] \(name): no AXWindows exposed — dumping the application element")
    walk(appEl, depth: 0, into: &body)
} else {
    for (i, w) in windows.enumerated() {
        let title = str(w, "AXTitle").map { " \"\(clip($0))\"" } ?? ""
        body += "\n== window[\(i)]\(title) ==\n"
        walk(w, depth: 0, into: &body)
    }
}

var header = ""
header += "# AX dump — \(name) (\(bundle), pid \(pid))\n"
header += "# windows: \(windows.count)\n"
header += "# nodes: \(nodeCount)\(truncated ? " (TRUNCATED at \(MAX_NODES))" : "")"
header += ", with AXPress/AXOpen: \(pressableCount)\n"
header += "# roles: " + roleCounts.sorted { $0.value > $1.value }
    .map { "\($0.key)×\($0.value)" }.joined(separator: ", ") + "\n"
header += "# format: <indent><role>[<subrole>] \"label\" actions=[…] rect=(x,y w×h) en=N id=… SELECTED\n"

print(header + body)
eprint("[axdump] \(name): \(nodeCount) nodes, \(pressableCount) with AXPress/AXOpen")
