import Cocoa
import ApplicationServices

/// Resolves the frontmost application as an AX element + pid.
///
/// **Why NSWorkspace, not AXFocusedApplication**: the obvious AX way
/// — `AXUIElementCreateSystemWide()` + `AXFocusedApplication` — depends
/// on the target app cooperating with the AX keyboard-focus reporting
/// protocol. Electron apps (VS Code, Slack, Discord) do this
/// unreliably: the attribute intermittently returns nil even when the
/// app is plainly frontmost. That made the whole focused-app hint scan
/// (and the OmniParser screencap, which also resolves the focused app)
/// silently produce nothing — observed as "no focused app" in the log
/// right after clicking into VS Code.
///
/// `NSWorkspace.shared.frontmostApplication` comes from the activation
/// / window-server subsystem, completely independent of AX, and is
/// reliable for every app. `AXUIElementCreateApplication(pid)` then
/// always succeeds in *creating* the wrapper element (it's just a pid
/// box — no AX round-trip). Per-attribute queries on it can still fail
/// per-app, but at least we've correctly identified the app.
@MainActor
enum FocusedApp {
    static func current() -> (element: AXUIElement, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        return (AXUIElementCreateApplication(pid), pid)
    }
}
