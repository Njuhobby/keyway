import Cocoa

enum Arrow {
    case left, right, up, down

    var keyCode: CGKeyCode {
        switch self {
        case .left:  return CGKeyCode(KeyCode.arrowLeft)
        case .right: return CGKeyCode(KeyCode.arrowRight)
        case .down:  return CGKeyCode(KeyCode.arrowDown)
        case .up:    return CGKeyCode(KeyCode.arrowUp)
        }
    }
}

enum KeyPoster {
    static func send(arrow: Arrow, shift: Bool) {
        post(keyCode: arrow.keyCode, flags: shift ? .maskShift : [])
    }

    static func copy() {
        post(keyCode: CGKeyCode(KeyCode.c), flags: .maskCommand)
    }

    static func escape() {
        post(keyCode: CGKeyCode(KeyCode.escape), flags: [])
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
            let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }

        for ev in [down, up] {
            ev.flags = flags
            ev.setIntegerValueField(.eventSourceUserData, value: HotkeyTap.syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
    }
}
