import Cocoa
import ApplicationServices

/// Waits (notification-driven) for the focused window to change after a
/// synthesized click, so a sticky re-hint can re-scan once an
/// asynchronously-opened window / switched app actually becomes focused.
///
/// Two sources, because one click can change focus two ways:
///   - `kAXFocusedWindowChangedNotification` on the focused app — a new
///     window inside the SAME app. May not fire on AX-poor apps
///     (Electron); the timeout covers those.
///   - `NSWorkspace.didActivateApplicationNotification` — focus moved to
///     ANOTHER app. Reliable, AX-independent.
///
/// Fires `onChange` at most once, then tears down. If nothing fires
/// within `timeoutMs`, tears down silently (the caller's immediate
/// re-hint was already correct — synchronous UI update or plain click).
///
/// This is a more general successor to the old AXWait (which only
/// awaited a specific app's activation).
@MainActor
final class FocusChangeWatcher {
    private var axObserver: AXObserver?
    private var appElement: AXUIElement?
    private var workspaceToken: NSObjectProtocol?
    private var timeoutItem: DispatchWorkItem?
    private var onChange: (() -> Void)?

    func start(pid: pid_t, timeoutMs: Int, onChange: @escaping () -> Void) {
        stop()   // reset any prior watch
        self.onChange = onChange

        // (1) AX observer — same-app focused-window change.
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<FocusChangeWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.fire() }
        }
        var obs: AXObserver?
        if AXObserverCreate(pid, callback, &obs) == .success, let obs {
            let app = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, app,
                                      kAXFocusedWindowChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = obs
            appElement = app
        }

        // (2) NSWorkspace — switched to another app.
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }

        // (3) Timeout fallback.
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeoutMs) / 1000.0,
                                      execute: item)
    }

    func stop() {
        if let obs = axObserver, let app = appElement {
            AXObserverRemoveNotification(obs, app,
                                         kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        appElement = nil
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceToken = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        onChange = nil
    }

    private func fire() {
        guard let cb = onChange else { return }   // already fired / stopped
        stop()                                    // one-shot
        cb()
    }
}
