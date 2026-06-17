import Cocoa
import ApplicationServices

/// Tracks which PIDs own menu bar extras so `HintMode.collectAll` only
/// has to query the ~10 PIDs that actually have something to return,
/// instead of poking all ~100 running apps every time the user presses
/// the trigger key.
///
/// Populated asynchronously at launch (~500ms in the background, off
/// the user's path) and kept fresh by subscribing to NSWorkspace
/// launch / terminate notifications — those are push events from the
/// OS, not polling, so steady-state cost is effectively zero.
///
/// `@unchecked Sendable` because all mutable state lives behind an
/// NSLock; Swift can't infer the invariant.
final class MenuExtraCache: @unchecked Sendable {
    static let shared = MenuExtraCache()

    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.probeAndMaybeAdd(pid: app.processIdentifier, delay: 1.0)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.remove(pid: app.processIdentifier)
        })
    }

    /// Kick off the initial parallel scan across every running app.
    /// Returns immediately; the cache fills in the background, typically
    /// in a few hundred ms. Safe to call before the user has triggered
    /// anything — the worst case (user hits the trigger before warmup
    /// finishes) is a partial hint set on the very first invocation.
    func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let allPIDs: [pid_t] = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy != .prohibited
                          && $0.processIdentifier != ownPID }
                .map { $0.processIdentifier }

            let bag = PIDBag()
            DispatchQueue.concurrentPerform(iterations: allPIDs.count) { i in
                if Self.appHasMenuExtras(pid: allPIDs[i]) {
                    bag.add(allPIDs[i])
                }
            }
            let found = bag.snapshot()
            self.lock.lock()
            self.pids = found
            self.lock.unlock()
            Log.debug("[keyway] menu extras cache warmed: \(found.count) PIDs")
        }
    }

    /// Snapshot of PIDs to scan during a TAP collect pass.
    func currentPIDs() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pids)
    }

    // MARK: - NSWorkspace event handlers

    private func probeAndMaybeAdd(pid: pid_t, delay: TimeInterval) {
        // Newly-launched apps need a moment to wire up their AX bridge
        // before queries return useful answers — probing instantly
        // tends to come back empty even for apps that DO have extras.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            [weak self] in
            guard let self = self, Self.appHasMenuExtras(pid: pid) else { return }
            self.lock.lock()
            self.pids.insert(pid)
            self.lock.unlock()
        }
    }

    private func remove(pid: pid_t) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    // MARK: - Probe

    /// Cheap presence check: does this PID expose any menu bar extra at
    /// all? We don't enumerate the children here — `HintMode` does that
    /// fresh on every trigger. We just decide whether the PID belongs
    /// in the cache.
    private static func appHasMenuExtras(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var extrasRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
           extrasRef != nil {
            return true
        }
        // Legacy shape: some agents expose `AXMenuExtra` directly under
        // the app root instead of under `AXExtrasMenuBar`.
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXChildren" as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return false }
        for child in children {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, "AXRole" as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXMenuExtra" {
                return true
            }
        }
        return false
    }
}

/// Thread-safe set used by warmUp's concurrent workers.
private final class PIDBag: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    func add(_ pid: pid_t) {
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }
    func snapshot() -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }
}
