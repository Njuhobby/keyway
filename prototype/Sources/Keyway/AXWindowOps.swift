import Cocoa
import ApplicationServices

/// AX helpers for the WINDOW mode: locate the focused app's frontmost
/// window, probe whether its position+size are writable, and read/write
/// its screen rect.
///
/// **Why a probe?** Native AppKit windows almost always expose `AXSize`
/// and `AXPosition` as writable, so direct AX writes give us instant,
/// no-animation resize. Some apps (older Electron, non-AppKit
/// custom-toolkit apps) leave them read-only — for those we fall back
/// to synthesized mouse-edge drag (slower, has animation, less precise,
/// but works on anything that the user can resize by clicking the
/// border manually). The probe at mode entry decides the path.
@MainActor
enum AXWindowOps {
    /// Frontmost window of the focused app — same chain as
    /// `ScreenCapture.focusedWindow()` (AXFocusedWindow → AXMainWindow
    /// → AXWindows[0]) so we land on the same window the user sees on
    /// top. Returns nil if no window can be resolved.
    static func frontmostWindow() -> AXUIElement? {
        guard let (app, _) = FocusedApp.current() else { return nil }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &ref) == .success,
           let raw = ref {
            return (raw as! AXUIElement)
        }
        ref = nil
        if AXUIElementCopyAttributeValue(app, "AXMainWindow" as CFString, &ref) == .success,
           let raw = ref {
            return (raw as! AXUIElement)
        }
        ref = nil
        if AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement],
           let first = windows.first {
            return first
        }
        return nil
    }

    /// True only if **both** `AXSize` and `AXPosition` are writable on
    /// this window — that's what direct AX resize needs (top/left edge
    /// expansion changes both).
    static func isResizable(_ window: AXUIElement) -> Bool {
        return isSettable(window, attribute: "AXSize")
            && isSettable(window, attribute: "AXPosition")
    }

    /// True if `AXPosition` alone is writable — looser than
    /// `isResizable` because translating a window only writes the
    /// origin. Some apps allow move but not resize (rare); checked
    /// separately so MOVE mode can accept them.
    static func isMovable(_ window: AXUIElement) -> Bool {
        return isSettable(window, attribute: "AXPosition")
    }

    /// True if the window exposes any of the standard title-bar buttons
    /// (close / minimize / zoom / fullscreen). Used as the "is this a
    /// real user window?" gate at WINDOW-mode entry:
    ///
    ///   - **Finder Desktop** (when no Finder window is open,
    ///     `AXFocusedWindow` returns the Desktop) has none of these
    ///     buttons and isn't user-resizable. Rejected.
    ///   - **macOS fullscreen** hides the buttons. Fullscreen windows
    ///     can't be resized anyway. Rejected (correct).
    ///   - **AX-poor apps** (Electron etc.) typically still expose the
    ///     buttons because their outer NSWindow chrome is native — the
    ///     AX black hole is the *content*, not the window frame. Passes.
    ///
    /// More reliable than `AXSubrole` for AX-poor apps (those often
    /// have nil / wrong subrole). Costs up to 4 IPC (short-circuits on
    /// the first hit), one-time at mode entry.
    static func hasTitleBarButton(_ window: AXUIElement) -> Bool {
        for attr in ["AXCloseButton", "AXMinimizeButton",
                     "AXZoomButton", "AXFullScreenButton"] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, attr as CFString, &ref) == .success,
               ref != nil {
                return true
            }
        }
        return false
    }

    private static func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// Read the window's current screen rect (AX global coords, top-left
    /// origin, points). Two IPC. Returns nil if either attribute can't
    /// be read.
    static func readRect(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, "AXSize" as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Write just the window's origin (for MOVE — translating without
    /// resizing). One IPC vs `writeRect`'s two.
    @discardableResult
    static func writePosition(_ window: AXUIElement, origin: CGPoint) -> Bool {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return false }
        return AXUIElementSetAttributeValue(window, "AXPosition" as CFString, value) == .success
    }

    /// Write just the window's size (for the size-first / anchored-
    /// position-second resize pattern in `WindowController`). One IPC.
    @discardableResult
    static func writeSize(_ window: AXUIElement, size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, "AXSize" as CFString, value) == .success
    }

    /// Write the window's rect. Two IPC writes. Returns false on any
    /// failure (app may have ignored / clamped — that's fine, the
    /// caller's in-memory rect can drift slightly without breaking).
    @discardableResult
    static func writeRect(_ window: AXUIElement, rect: CGRect) -> Bool {
        var origin = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        // Position first, then size: when we expand from a top/left edge
        // we're moving the origin "outward" while growing the size. If
        // we wrote size first, the app might briefly see "old position +
        // new size" — which can hit max-size clamps or look jumpy.
        let posErr = AXUIElementSetAttributeValue(window, "AXPosition" as CFString, posValue)
        let sizeErr = AXUIElementSetAttributeValue(window, "AXSize" as CFString, sizeValue)
        return posErr == .success && sizeErr == .success
    }
}
