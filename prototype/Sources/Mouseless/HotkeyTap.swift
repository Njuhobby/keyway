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

    /// F19 (= remapped Caps Lock) chord/tap disambiguation, in ALL modes.
    /// Bare F19 keyDown *arms* instead of acting immediately — we wait
    /// for the F19 keyUp. If a `d` arrives while armed, it's the scroll
    /// chord (Caps Lock + d → SCROLL) and we set chordUsed so the
    /// eventual F19 keyUp does NOT also fire the per-mode tap action
    /// (enter TAP / toggle sticky / SCROLL→TAP). Deferring to keyUp costs
    /// ~50ms (imperceptible) but lets the chord pre-empt the tap.
    /// See `specs/scroll-mode-design.md` §2.1.
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
            // F19 release resolves an armed press. If no j/k chord was
            // used during the hold, perform the trigger's per-mode
            // default (OFF→TAP, TAP→sticky toggle, SCROLL→TAP). See
            // scroll-mode-design.md §2.1 — the arm now spans all modes.
            if keyCode == KeyCode.f19 {
                if f19Armed {
                    let wasChord = f19ChordUsed
                    f19Armed = false
                    f19ChordUsed = false
                    if !wasChord {
                        session.handleTriggerTap()
                    }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            // Other releases route to the session (scroll/move stop).
            if session.isActive, session.handleKeyUp(keyCode: keyCode) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // ---- keyDown ----
        // Bare F19 (= remapped Caps Lock) → ARM, in ANY mode. Don't act
        // yet: wait for keyUp, so a j/k chord can divert to SCROLL first.
        // Modifier+F19 is left for the user to bind elsewhere.
        let modifierMask: CGEventFlags = [.maskShift, .maskControl,
                                          .maskCommand, .maskAlternate]
        if keyCode == KeyCode.f19 && flags.intersection(modifierMask).isEmpty {
            f19Armed = true
            f19ChordUsed = false
            return nil
        }
        // F19 held + d → SCROLL chord, from any mode. (d as in "down /
        // scroll"; matches SCROLL's d-to-scroll-down key. Not j/k —
        // those are unified cursor-move keys now.) Synchronous (cheap AX
        // scroll-area walk); consume the chord key.
        if f19Armed && keyCode == KeyCode.d {
            f19ChordUsed = true
            session.enterScroll()
            return nil
        }
        // F19 held + w → WINDOW (resize) chord, from any mode. (w for
        // "window".) VimSession probes hasTitleBarButton + isResizable
        // and refuses with a HUD note if either fails.
        if f19Armed && keyCode == KeyCode.w {
            f19ChordUsed = true
            session.enterWindowMode()
            return nil
        }
        // F19 held + m → MOVE chord, from any mode. (m for "move".)
        // Mirror of WINDOW: same hasTitleBarButton gate, but the
        // second gate is the looser isMovable (just AXPosition
        // settable — translation doesn't change size).
        if f19Armed && keyCode == KeyCode.m {
            f19ChordUsed = true
            session.enterWindowMove()
            return nil
        }

        // In a mode — handler decides whether to consume the event.
        if session.isActive {
            return session.handle(keyCode: keyCode, flags: flags)
                ? nil
                : Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }
}
