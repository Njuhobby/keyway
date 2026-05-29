import Cocoa
import ApplicationServices

/// After a sticky-mode commit, the synthesized click can change the
/// **same app's** UI asynchronously — list selection → detail pane
/// reload, disclosure expand, in-place navigation, a popover opening, or
/// a new window inside that app. The immediate re-hint can't see it (it
/// walks the AX tree before the click is even processed), so this watcher
/// listens (notification-driven, no polling) for AX change notifications
/// on the app element and calls `onChange` to re-hint against fresh
/// content.
///
/// Scope is deliberately **same-app, post-commit only**. Cross-app
/// switches (Cmd+Tab, or a click that activates another app) are handled
/// separately by VimSession's always-on app-switch follow — app
/// activation is a clean per-switch signal, whereas these AX content
/// notifications are noisy (a ticking clock posts `valueChanged`
/// constantly), so we only listen to them for `timeoutMs` after our own
/// click.
///
/// Bursts are coalesced. One click typically posts a flurry (old pane
/// `destroyed` → new elements `created` → `layoutChanged` → `valueChanged`).
/// Each notification (re)arms a `debounceMs` timer, so we fire once after
/// the burst settles rather than mid-update. A `maxLatencyMs` cap forces
/// a fire even under never-quiet apps (live timers / spinners that post
/// continuously). Fires may repeat until the hard `timeoutMs` — each
/// re-hint is generation-guarded in `VimSession`, so the latest scan
/// wins and earlier ones bow out.
///
/// Note: OmniParser-routed apps (webview / Electron) emit none of these
/// AX notifications, so this watcher does nothing for them — their
/// same-window content change is covered by VimSession's ~100ms delayed
/// re-hint instead. This watcher earns its keep on AX-whitelisted apps.
///
/// Successor to the old AXWait (single app-activation await) and
/// FocusChangeWatcher (focus-only).
@MainActor
final class PostCommitWatcher {
    private var axObserver: AXObserver?
    private var appElement: AXUIElement?
    private var hardTimeoutItem: DispatchWorkItem?
    private var debounceItem: DispatchWorkItem?
    private var onChange: (() -> Void)?
    private var debounceMs = 100
    private var maxLatencyMs = 400
    private var firstPendingAt: Date?

    /// AX notifications that signal "the UI the user is looking at
    /// changed". Registered on the application element, which receives
    /// them app-wide (posted by whichever descendant actually changed).
    /// Best-effort: an app that doesn't support a given notification just
    /// returns an error on add, which we ignore.
    private static let axNotifications: [CFString] = [
        // focus / window
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString,
        // same-window content
        kAXValueChangedNotification as CFString,
        kAXLayoutChangedNotification as CFString,
        kAXSelectedRowsChangedNotification as CFString,
        kAXSelectedChildrenChangedNotification as CFString,
        kAXRowCountChangedNotification as CFString,
        kAXCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXTitleChangedNotification as CFString,
    ]

    func start(pid: pid_t, timeoutMs: Int, debounceMs: Int = 100,
               maxLatencyMs: Int = 400, onChange: @escaping () -> Void) {
        stop()   // reset any prior watch
        self.onChange = onChange
        self.debounceMs = debounceMs
        self.maxLatencyMs = maxLatencyMs

        // (1) AX observer — same-app window + content notifications.
        let callback: AXObserverCallback = { _, _, notif, refcon in
            guard let refcon else { return }
            let name = notif as String
            let watcher = Unmanaged<PostCommitWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.noteChange(name) }
        }
        var obs: AXObserver?
        if AXObserverCreate(pid, callback, &obs) == .success, let obs {
            let app = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in Self.axNotifications {
                AXObserverAddNotification(obs, app, n, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = obs
            appElement = app
        }

        // (2) Hard timeout — stop listening for good.
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        hardTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeoutMs) / 1000.0,
                                      execute: item)
    }

    func stop() {
        if let obs = axObserver, let app = appElement {
            for n in Self.axNotifications {
                AXObserverRemoveNotification(obs, app, n)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        appElement = nil
        hardTimeoutItem?.cancel()
        hardTimeoutItem = nil
        debounceItem?.cancel()
        debounceItem = nil
        firstPendingAt = nil
        onChange = nil
    }

    /// A change notification arrived — (re)arm the debounce so a burst
    /// settles into one re-hint. If we've been deferring past
    /// `maxLatencyMs` (continuous events), fire now instead of waiting
    /// for a quiet that may never come.
    private func noteChange(_ name: String) {
        guard onChange != nil else { return }   // already stopped
        print("[mouseless] post-commit AX notif: \(name)")
        let now = Date()
        if firstPendingAt == nil { firstPendingAt = now }
        if let first = firstPendingAt,
           now.timeIntervalSince(first) * 1000 >= Double(maxLatencyMs) {
            fire()
            return
        }
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(debounceMs) / 1000.0,
                                      execute: item)
    }

    /// Re-hint now. NOT one-shot: we keep observing until the hard
    /// timeout so multi-stage updates (a second pane that loads later)
    /// are caught too. `VimSession`'s generation guard makes repeated
    /// fires safe.
    private func fire() {
        guard let cb = onChange else { return }
        debounceItem?.cancel()
        debounceItem = nil
        firstPendingAt = nil
        print("[mouseless] post-commit recheck → re-hint")
        cb()
    }
}
