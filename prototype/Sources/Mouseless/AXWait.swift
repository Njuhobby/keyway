import Cocoa
import ApplicationServices

/// Suspend a Task until a specific OS event fires, with a timeout
/// fallback so silent failures don't deadlock the caller.
///
/// `appActivated(bundleID:)` returns `true` if the NSWorkspace
/// notification fired, `false` if `timeoutMs` elapsed first. The
/// timeout is a defensive fallback for the (rare in practice but
/// real) case where the notification just doesn't get posted.
@MainActor
enum AXWait {
    /// Wait for the given app to become frontmost. If it is already
    /// active, returns true immediately without suspending.
    static func appActivated(
        bundleID: String,
        timeoutMs: Int
    ) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            return true
        }
        let nc = NSWorkspace.shared.notificationCenter
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let gate = OneShot()
            // Box the observer ref so both the @Sendable notification
            // handler and the @MainActor timeout Task can read/clear
            // it. Both paths run on the main thread (queue: .main +
            // @MainActor) so concurrent access is impossible in
            // practice — `@unchecked Sendable` tells the compiler we
            // know.
            let slot = Box<NSObjectProtocol>()
            slot.value = nc.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { notif in
                let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                if let o = slot.value { nc.removeObserver(o); slot.value = nil }
                MainActor.assumeIsolated {
                    gate.resume(cont, with: true)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if let o = slot.value { nc.removeObserver(o); slot.value = nil }
                gate.resume(cont, with: false)
            }
        }
    }

}

/// One-shot gate ensuring a continuation resumes exactly once even
/// when both a notification and a timeout path can race to it.
/// Calling `resume` twice on a `CheckedContinuation` is a runtime
/// crash; the gate suppresses the loser. Constrained to `Sendable`
/// payloads because `resume(returning:)` takes a sending parameter.
@MainActor
private final class OneShot {
    private var fired = false
    func resume<T: Sendable>(_ cont: CheckedContinuation<T, Never>, with value: T) {
        if fired { return }
        fired = true
        cont.resume(returning: value)
    }
}

/// Mutable reference cell for state shared between an `@Sendable`
/// callback and an `@MainActor` Task. `@unchecked Sendable` is the
/// standard escape hatch — synchronization comes from the caller
/// arranging that all accesses happen on the same thread.
private final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ v: T? = nil) { value = v }
}
