@preconcurrency import Cocoa
import ApplicationServices

@MainActor
final class HotkeyTap {
    /// Marker stored in `eventSourceUserData` on every event we synthesize, so our
    /// own callback can short-circuit and avoid feedback loops. `nonisolated` so
    /// `KeyPoster` can stamp events from any actor context.
    nonisolated static let syntheticMarker: Int64 = 0x4D4F5553  // "MOUS"

    private let session: VimSession
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(session: VimSession) {
        self.session = session
    }

    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let owner = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            // The tap callback runs on the run loop the source is attached to (main).
            return MainActor.assumeIsolated {
                owner.handle(type: type, event: event)
            }
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[mouseless] CGEvent.tapCreate returned nil — accessibility likely not granted.")
            return false
        }

        tap = newTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the OS disabled it (slow callback or user input race).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Pass through events we synthesized ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if !session.isActive {
            // Activation: bare F19 — no modifiers. The user is expected to
            // have remapped Caps Lock → F19 via hidutil (see setup-trigger.sh).
            // F19 is unused by any app, so it's a collision-free "Hyper"
            // key. We still require no modifiers to keep Shift/Cmd/Ctrl/
            // Option + F19 free for the user to bind elsewhere if they
            // ever want to.
            let modifierMask: CGEventFlags = [.maskShift, .maskControl,
                                              .maskCommand, .maskAlternate]
            if keyCode == KeyCode.f19 && flags.intersection(modifierMask).isEmpty {
                // enter() is async — its OP path may run ScreenCaptureKit
                // + CoreML inference. Dispatch fire-and-forget; the event
                // tap callback must return synchronously, but we already
                // know we want to consume this event (return nil).
                Task { @MainActor [session] in
                    await session.enter()
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // In vim mode — handler decides whether to consume the event.
        return session.handle(keyCode: keyCode, flags: flags)
            ? nil
            : Unmanaged.passUnretained(event)
    }
}
