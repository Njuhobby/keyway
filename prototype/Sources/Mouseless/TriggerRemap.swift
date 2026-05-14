import Foundation

/// Owns the lifecycle of the Caps Lock → F19 HID remap.
///
/// macOS treats Caps Lock as a modifier key, not a regular key — pressing it
/// only emits `flagsChanged`, never `keyDown`, and the OS adds a built-in
/// toggle delay. CGEventTap can't grab it as a trigger key in that form.
/// `hidutil` rewrites the HID usage code *before* the modifier handling
/// kicks in: physical Caps Lock starts sending F19 keyDown events, which
/// our event tap matches normally (see `HotkeyTap.swift`).
///
/// The remap is **session-scoped**: it lasts until the user reboots or
/// reverts it. We manage that lifecycle here:
///
///   - `applyAtLaunch()` —  called once after AX permission is granted.
///   - `revertAtQuit()` —  called from `applicationWillTerminate`.
///
/// User-visible: install Mouseless → it just works. Quit Mouseless → Caps
/// Lock goes back to normal typing toggle.
///
/// Caveat: `applicationWillTerminate` isn't fired on force-quit / crash /
/// system shutdown. In those cases the remap persists until the next
/// reboot (or until Mouseless is launched again and reapplies, harmlessly).
/// Acceptable degradation — the user can always reboot or run `hidutil
/// property --set '{"UserKeyMapping":[]}'` to clear it manually.
enum TriggerRemap {
    /// HID usage codes (USB HID Keyboard/Keypad Page = 0x07).
    /// Caps Lock = 0x39, F19 = 0x6E. The 0x700000000 prefix is the page id.
    private static let capsLockUsage: UInt64 = 0x7_0000_0039
    private static let f19Usage: UInt64 = 0x7_0000_006E

    private static let applyJSON: String = """
    {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(capsLockUsage),"HIDKeyboardModifierMappingDst":\(f19Usage)}]}
    """
    private static let clearJSON = #"{"UserKeyMapping":[]}"#

    /// Apply the Caps Lock → F19 remap. Idempotent — calling twice is fine.
    /// Returns true on success.
    @discardableResult
    static func applyAtLaunch() -> Bool {
        let ok = runHIDUtil(arguments: ["property", "--set", applyJSON])
        if ok {
            print("[mouseless] Caps Lock → F19 remap applied via hidutil.")
        } else {
            print("[mouseless] WARNING: hidutil remap failed. Caps Lock won't trigger Mouseless.")
            print("           Run `./setup-trigger.sh` manually, or check that /usr/bin/hidutil exists.")
        }
        return ok
    }

    /// Clear the Caps Lock remap (back to normal toggle behavior).
    /// Best-effort: doesn't block app teardown if it fails.
    static func revertAtQuit() {
        _ = runHIDUtil(arguments: ["property", "--set", clearJSON])
    }

    private static func runHIDUtil(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        // Swallow stdout/stderr — hidutil prints the full property dict on
        // success which would clutter our log.
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
