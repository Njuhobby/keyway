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

    /// F19 (= remapped Caps Lock) chord/tap disambiguation, used only in
    /// the OFF state. Bare F19 keyDown *arms* instead of immediately
    /// entering TAP — we wait for the F19 keyUp. If a j/k arrives while
    /// armed, it's a scroll chord (Caps Lock + j/k → SCROLL) and we set
    /// chordUsed so the eventual F19 keyUp does NOT also enter TAP.
    /// Deferring TAP to keyUp costs ~50ms (the hold duration of a tap,
    /// imperceptible) but lets the scroll chord skip the TAP scan
    /// entirely. See `specs/scroll-mode-design.md` §2.1.
    private var f19Armed = false
    private var f19ChordUsed = false

    init(session: VimSession) {
        self.session = session
    }

    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
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

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // ---- keyUp ----
        if type == .keyUp {
            // F19 release resolves an armed tap: enter TAP iff no scroll
            // chord (j/k) was used during the hold.
            if keyCode == KeyCode.f19 {
                if f19Armed {
                    let enterTap = !f19ChordUsed
                    f19Armed = false
                    f19ChordUsed = false
                    if enterTap && !session.isActive {
                        Task { @MainActor [session] in await session.enter() }
                    }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            // Other releases route to the session (scroll stop on j/k up).
            if session.isActive, session.handleKeyUp(keyCode: keyCode) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // ---- keyDown ----
        if !session.isActive {
            let modifierMask: CGEventFlags = [.maskShift, .maskControl,
                                              .maskCommand, .maskAlternate]
            // Bare F19 (= remapped Caps Lock) → ARM. Don't enter TAP yet:
            // we wait for keyUp so a j/k chord can divert to SCROLL first.
            if keyCode == KeyCode.f19 && flags.intersection(modifierMask).isEmpty {
                f19Armed = true
                f19ChordUsed = false
                return nil
            }
            // F19 held + j/k → SCROLL chord. enterScroll is async (S3 AX
            // walk); dispatch fire-and-forget, consume the chord key.
            if f19Armed && (keyCode == KeyCode.j || keyCode == KeyCode.k) {
                f19ChordUsed = true
                Task { @MainActor [session] in await session.enterScroll() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // In a mode — handler decides whether to consume the event.
        return session.handle(keyCode: keyCode, flags: flags)
            ? nil
            : Unmanaged.passUnretained(event)
    }
}
