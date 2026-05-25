import Cocoa
import ApplicationServices
import ScreenCaptureKit

/// Capture the user's currently focused window as a CGImage.
///
/// **Why a window, not the full screen**: the OmniParser fallback path
/// exists to fill the AX black hole inside a single app's window
/// (Electron / WKWebView / Catalyst child elements). The AX path already
/// handles Dock / menu bar / menu extras well, so OmniParser doesn't
/// need to see those — and dragging them into the model would cause
/// hint label collisions with the AX path. See
/// `specs/omniparser-fallback-design.md` §6.4.
///
/// **Why we can rely on AX for the window even when AX is "bad"**: the
/// AX black hole only affects the **child element tree** inside a
/// window (every button becomes AXGroup). The **window skeleton**
/// (AXFocusedWindow, AXPosition, AXSize, CGWindowID) is filled in by
/// macOS itself at NSWindow creation, independent of the app's AX
/// implementation. So Electron / Catalyst / WKWebView apps all report
/// their focused window correctly.
@MainActor
enum ScreenCapture {
    /// End-to-end: AX → CGWindowID → ScreenCaptureKit → CGImage.
    /// Returns nil if any link fails (no focused window, no permission,
    /// SC content out of sync, etc.). Callers should treat nil as
    /// "no OmniParser candidates this scan" and continue with AX-only.
    static func captureFocusedWindow() async -> CGImage? {
        guard let cgWindowID = focusedCGWindowID() else {
            print("[mouseless] ScreenCapture: no focused window (AX chain returned nil)")
            return nil
        }

        // Lazy permission: only ask when we actually need to capture.
        // First call without permission triggers the native TCC prompt
        // via CGRequestScreenCaptureAccess. The user has to grant it +
        // restart the app — there's no "wait for grant" API. So this
        // attempt fails; the *next* trigger (after restart) succeeds.
        guard CGPreflightScreenCaptureAccess() else {
            print("[mouseless] ScreenCapture: requesting Screen Recording permission")
            _ = CGRequestScreenCaptureAccess()
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let scWindow = content.windows.first(where: { $0.windowID == cgWindowID })
            else {
                print("[mouseless] ScreenCapture: windowID \(cgWindowID) not in SC content")
                return nil
            }

            // desktopIndependentWindow mode: paints the window's *own*
            // content, ignoring whatever (other window / menu bar / etc)
            // is occluding it. We want the full UI for OmniParser to
            // analyze, not a partial view.
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            // Match the retina pixel resolution of the window — using
            // the filter's contentRect (in points) × 2 for typical
            // Apple Silicon displays. SC will scale appropriately.
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            print("[mouseless] ScreenCapture failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Permission helpers (exposed for AppDelegate banner/UI)

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Debug

    /// P2-only: capture focused window and write to /tmp/mouseless-focused.png
    /// for visual inspection. Runs in a Task — does not block the caller.
    /// Strip once OmniParser integration replaces /tmp dump with actual
    /// downstream pipeline.
    static func debugCaptureToTmp() {
        Task { @MainActor in
            let t0 = Date()
            guard let image = await captureFocusedWindow() else {
                print("[mouseless] debug capture: returned nil (see preceding log)")
                return
            }
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            let path = "/tmp/mouseless-focused.png"
            let url = URL(fileURLWithPath: path)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
            ) else {
                print("[mouseless] debug capture: failed to open \(path)")
                return
            }
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) {
                print("[mouseless] debug capture: \(image.width)×\(image.height) in \(elapsed)ms → \(path)")
            } else {
                print("[mouseless] debug capture: write failed")
            }
        }
    }

    // MARK: - AX chain

    /// AXFocusedApplication → AXFocusedWindow → CGWindowID.
    /// Each link can fail independently; returns nil if any does.
    /// Logs the specific failure step so we can diagnose AX-bad apps.
    private static func focusedCGWindowID() -> CGWindowID? {
        let sys = AXUIElementCreateSystemWide()

        // Step 1: AXFocusedApplication
        var appRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(
            sys, "AXFocusedApplication" as CFString, &appRef
        )
        guard appErr == .success, let appRaw = appRef else {
            print("[mouseless] AX step 1 (AXFocusedApplication): err=\(axErrName(appErr)) nil=\(appRef == nil)")
            return nil
        }
        let app = appRaw as! AXUIElement

        // Identify which app we're talking to (helps debug Electron quirks)
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        print("[mouseless] AX step 1 ok: pid=\(pid) bundleID=\(bundleID)")

        // Step 2: AXFocusedWindow
        var winRef: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(
            app, "AXFocusedWindow" as CFString, &winRef
        )
        let win: AXUIElement
        if winErr == .success, let winRaw = winRef {
            win = winRaw as! AXUIElement
            print("[mouseless] AX step 2 (AXFocusedWindow): ok")
        } else {
            print("[mouseless] AX step 2 (AXFocusedWindow): err=\(axErrName(winErr)) nil=\(winRef == nil) — trying fallbacks")
            // Fallback A: AXMainWindow (set on app launch, doesn't need key state)
            var mainRef: CFTypeRef?
            let mainErr = AXUIElementCopyAttributeValue(
                app, "AXMainWindow" as CFString, &mainRef
            )
            if mainErr == .success, let mainRaw = mainRef {
                win = mainRaw as! AXUIElement
                print("[mouseless] AX step 2 fallback A (AXMainWindow): ok")
            } else {
                // Fallback B: AXWindows[0] (z-ordered, frontmost first)
                var windowsRef: CFTypeRef?
                let windowsErr = AXUIElementCopyAttributeValue(
                    app, "AXWindows" as CFString, &windowsRef
                )
                guard windowsErr == .success,
                      let windows = windowsRef as? [AXUIElement],
                      let first = windows.first
                else {
                    print("[mouseless] AX step 2 fallback B (AXWindows[0]): err=\(axErrName(windowsErr)) count=\((windowsRef as? [AXUIElement])?.count ?? -1) — giving up")
                    return nil
                }
                win = first
                print("[mouseless] AX step 2 fallback B (AXWindows[0]): ok, \(windows.count) windows total")
            }
        }

        // Step 3: AXUIElement → CGWindowID via private API
        // `_AXUIElementGetWindow` is private (note leading underscore)
        // but extremely stable — Hammerspoon, Rectangle, Raycast, and
        // dozens of other macOS automation tools rely on it. The
        // public alternative (CGWindowListCopyWindowInfo + match by
        // PID + title) is slower and brittle when titles change.
        var cgWindowID: CGWindowID = 0
        let idErr = _AXUIElementGetWindow(win, &cgWindowID)
        guard idErr == .success, cgWindowID != 0 else {
            print("[mouseless] AX step 3 (_AXUIElementGetWindow): err=\(axErrName(idErr)) id=\(cgWindowID)")
            return nil
        }
        print("[mouseless] AX step 3 ok: CGWindowID=\(cgWindowID)")
        return cgWindowID
    }

    private static func axErrName(_ err: AXError) -> String {
        switch err {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(err.rawValue))"
        }
    }
}

// Private AX API to bridge AXUIElement → CGWindowID. Declared here as
// a Swift `@_silgen_name` shim so we don't need a separate bridging
// header.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError
