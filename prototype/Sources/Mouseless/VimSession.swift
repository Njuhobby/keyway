import Cocoa

@MainActor
final class VimSession {
    private(set) var isActive = false
    private var selecting = false
    private var hint: HintMode?

    func enter() {
        guard !isActive else { return }
        isActive = true
        selecting = false
        HUD.shared.show("VIM")
        print("[mouseless] enter vim mode")
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        selecting = false
        if let h = hint {
            h.deactivate()
            hint = nil
        }
        HUD.shared.hide()
        print("[mouseless] exit vim mode")
    }

    /// Returns `true` if the event was consumed and should be dropped.
    /// While vim mode is active we swallow every keyDown so nothing leaks
    /// through to the focused app — that's the price of a modal layer.
    func handle(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard isActive else { return false }

        // Hint mode swallows all keystrokes until it commits or cancels.
        if let h = hint {
            if keyCode == KeyCode.escape {
                h.deactivate()
                hint = nil
                HUD.shared.show(selecting ? "VIM · SEL" : "VIM")
                return true
            }
            guard let ch = Self.alphabetChar(for: keyCode) else { return true }
            switch h.handle(char: ch) {
            case .pending:
                break
            case .committed, .cancelled:
                hint = nil
                HUD.shared.show(selecting ? "VIM · SEL" : "VIM")
            }
            return true
        }

        switch keyCode {
        case KeyCode.escape:
            exit()
        case KeyCode.h:
            KeyPoster.send(arrow: .left, shift: selecting)
        case KeyCode.j:
            KeyPoster.send(arrow: .down, shift: selecting)
        case KeyCode.k:
            KeyPoster.send(arrow: .up, shift: selecting)
        case KeyCode.l:
            KeyPoster.send(arrow: .right, shift: selecting)
        case KeyCode.v:
            selecting.toggle()
            HUD.shared.show(selecting ? "VIM · SEL" : "VIM")
        case KeyCode.y:
            KeyPoster.copy()
            exit()
        case KeyCode.f:
            let h = HintMode()
            if h.activate() {
                hint = h
            } else {
                HUD.shared.show("VIM · no hints here")
            }
        default:
            break
        }
        return true
    }

    /// Map physical key codes to the homerow alphabet used for hint labels.
    private static func alphabetChar(for keyCode: Int) -> Character? {
        switch keyCode {
        case KeyCode.a: return "a"
        case KeyCode.s: return "s"
        case KeyCode.d: return "d"
        case KeyCode.f: return "f"
        case KeyCode.g: return "g"
        case KeyCode.h: return "h"
        case KeyCode.j: return "j"
        case KeyCode.k: return "k"
        case KeyCode.l: return "l"
        default: return nil
        }
    }
}
