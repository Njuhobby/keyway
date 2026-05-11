import Cocoa

/// Owns the active interaction mode + an optional command-palette overlay.
///
/// `mode` describes what the user is actually doing:
///   .tap      — default. Hints visible, picking one performs a click.
///   (future)  — .selectText(...), .drag(...), etc.
///
/// `paletteBuffer` is independent: when non-nil, the command palette is
/// open and intercepts keystrokes. The underlying mode is *unchanged* —
/// closing the palette returns you to the same mode you were already in.
@MainActor
final class VimSession {
    enum Mode {
        case tap(HintMode)
        // Future: case selectText(...), case drag(...), case rightClick(...)
    }

    private var mode: Mode? = nil
    private var paletteBuffer: String? = nil   // nil = palette closed
    private var sticky: Bool = false           // toggled by trigger key in TAP

    var isActive: Bool { mode != nil }

    // MARK: - Lifecycle

    /// Trigger key pressed → enter TAP mode (hints visible).
    func enter() {
        guard mode == nil else { return }
        let h = HintMode()
        guard h.activate() else {
            HUD.shared.show("no hints here")
            return
        }
        mode = .tap(h)
        paletteBuffer = nil
        sticky = false
        renderModeHUD()
        print("[mouseless] enter TAP mode")
    }

    func exit() {
        if case .tap(let h) = mode {
            h.deactivate()
        }
        mode = nil
        paletteBuffer = nil
        sticky = false
        HUD.shared.hide()
        print("[mouseless] exit")
    }

    // MARK: - Event entry point

    /// Returns `true` if the event was consumed.
    func handle(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard let m = mode else { return false }

        // Cmd / Ctrl held → system shortcut. Pass through so things like
        // Cmd+Shift+4 (screenshot), Cmd+Space (Spotlight), Cmd+Tab, and
        // Ctrl+Up (Mission Control) still work while Mouseless is active.
        // Shift / Option are reserved for hint click-action modifiers
        // (Shift = right-click, Option = double-click), so they stay.
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
            return false
        }

        // Palette open? It intercepts everything until closed.
        if let buffer = paletteBuffer {
            return handlePalette(buffer: buffer, keyCode: keyCode, flags: flags)
        }

        // Esc — always exits Mouseless completely.
        if keyCode == KeyCode.escape {
            exit()
            return true
        }
        // Shift+; (= ":") — open the command palette over the current mode.
        if keyCode == KeyCode.semicolon && flags.contains(.maskShift) {
            paletteBuffer = ""
            HUD.shared.show(":")
            return true
        }

        // Otherwise dispatch to the active mode.
        return handleMode(mode: m, keyCode: keyCode, flags: flags)
    }

    private func handleMode(mode: Mode, keyCode: Int, flags: CGEventFlags) -> Bool {
        switch mode {
        case .tap(let hint):
            return handleTap(hint: hint, keyCode: keyCode, flags: flags)
        }
    }

    // MARK: - TAP mode

    private func handleTap(hint: HintMode, keyCode: Int, flags: CGEventFlags) -> Bool {
        // Bare backtick (no modifiers) toggles sticky. While sticky is on,
        // each click re-scans hints instead of exiting.
        let modMask: CGEventFlags = [.maskShift, .maskControl,
                                     .maskCommand, .maskAlternate]
        if keyCode == KeyCode.grave && flags.intersection(modMask).isEmpty {
            sticky.toggle()
            renderModeHUD()
            return true
        }

        // Bare `x` — "click on empty space" gesture. Activating Finder
        // reproduces what physically clicking the desktop wallpaper does:
        // the previously focused app loses focus, any open menu/popover
        // closes, Finder becomes frontmost. No fake keystrokes, so we
        // dodge Esc's app-specific side effects (vim normal mode, dialog
        // cancel, terminal escape sequences, etc.). After the focus
        // switch we rescan so hints reflect Finder's UI.
        if keyCode == KeyCode.x && flags.intersection(modMask).isEmpty {
            hint.deactivate()
            if let finder = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.finder").first {
                finder.activate(options: [])
            }
            // Activation is asynchronous — AX `AXFocusedApplication`
            // still points at the previous app for a tick or two. Wait
            // briefly so the rescan walks Finder, not what we just left.
            // The Task also keeps the AX walk off the event-tap callback
            // so CGEventTap doesn't trip its user-input timeout.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard self.isActive else { return }
                let next = HintMode()
                if next.activate() {
                    self.mode = .tap(next)
                    self.renderModeHUD()
                } else {
                    self.exit()
                }
            }
            return true
        }

        guard let ch = Self.hintChar(for: keyCode) else { return true }

        // Modifier on the final hint letter chooses the click action.
        let action: ClickAction
        if flags.contains(.maskShift) {
            action = .right
        } else if flags.contains(.maskAlternate) {
            action = .double
        } else {
            action = .left
        }

        switch hint.handle(char: ch, action: action) {
        case .pending:
            break
        case .committed:
            if sticky {
                // Re-scan and stay in TAP for the next click.
                hint.deactivate()
                let nextHint = HintMode()
                if nextHint.activate() {
                    mode = .tap(nextHint)
                    renderModeHUD()
                } else {
                    exit()
                }
            } else {
                exit()
            }
        case .cancelled:
            exit()
        }
        return true
    }

    // MARK: - Palette overlay

    private func handlePalette(buffer: String, keyCode: Int, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case KeyCode.escape:
            // Esc fully exits Mouseless, regardless of palette state.
            exit()
            return true

        case KeyCode.return:
            executeCommand(buffer)
            return true

        case KeyCode.delete:
            // Backspace. Empty buffer + backspace closes the palette and
            // restores the current mode's HUD (mode itself is unchanged).
            if buffer.isEmpty {
                paletteBuffer = nil
                renderModeHUD()
            } else {
                var b = buffer
                b.removeLast()
                paletteBuffer = b
                HUD.shared.show(":\(b)")
            }
            return true

        default:
            // Append a letter; ignore other keys.
            guard let ch = Self.letterChar(for: keyCode) else { return true }
            let next = buffer + String(ch)
            paletteBuffer = next
            HUD.shared.show(":\(next)")
            return true
        }
    }

    // MARK: - Command dispatch

    private func executeCommand(_ cmd: String) {
        switch cmd {
        case "q":
            exit()

        // Future modes plug in here, e.g.:
        // case "st": switchTo(.selectText(...))
        // case "dr": switchTo(.drag(...))

        default:
            // Unknown command — clear the buffer, leave the palette open
            // so the user can type another command without reopening it.
            paletteBuffer = ""
            HUD.shared.show(":")
        }
    }

    // MARK: - HUD

    private func renderModeHUD(suffix: String = "") {
        guard let m = mode else { return }
        let label: String
        switch m {
        case .tap: label = sticky ? "TAP · sticky" : "TAP"
        }
        HUD.shared.show(label + suffix)
    }

    // MARK: - Key code → character

    /// Used while a mode is active (no palette). Accepts homerow letters and
    /// digits — both are valid hint labels (letters for app/menu hints,
    /// digits for Dock hints).
    private static func hintChar(for keyCode: Int) -> Character? {
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
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        default: return nil
        }
    }

    /// Used in the command palette — letters only.
    private static func letterChar(for keyCode: Int) -> Character? {
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
        case KeyCode.q: return "q"
        case KeyCode.w: return "w"
        case KeyCode.e: return "e"
        case KeyCode.r: return "r"
        case KeyCode.t: return "t"
        case KeyCode.y: return "y"
        case KeyCode.u: return "u"
        case KeyCode.i: return "i"
        case KeyCode.o: return "o"
        case KeyCode.p: return "p"
        case KeyCode.z: return "z"
        case KeyCode.x: return "x"
        case KeyCode.c: return "c"
        case KeyCode.v: return "v"
        case KeyCode.b: return "b"
        case KeyCode.n: return "n"
        case KeyCode.m: return "m"
        default: return nil
        }
    }
}
