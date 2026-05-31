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
    /// Captured window: the pixel image plus the window's screen-space
    /// rect in points (top-left origin, AX coordinate space). OP path
    /// needs both — image for inference, rect for translating normalized
    /// model output back to screen-space hint targets.
    struct Captured {
        let image: CGImage      // crop's pixel content
        let screenRect: CGRect  // window rect in points, AX coords
    }

    /// End-to-end: AX → focused window rect → display capture → crop.
    /// Returns nil if any link fails.
    ///
    /// **Why display capture + crop, not per-window capture**:
    /// `SCContentFilter(desktopIndependentWindow:)` forces WindowServer to
    /// re-render the window into an off-screen buffer to produce an
    /// occlusion-free image (~95ms). We don't need occlusion-free — at
    /// the moment the user presses Caps Lock, the focused window is
    /// almost always fully visible (that's what they're looking at).
    /// Reading the already-composited display framebuffer is much
    /// faster (~20-30ms) since no recomposition is required.
    /// See `omniparser-fallback-design.md` §6.4.
    /// `isolateApp`: exclude the **Dock** process from the capture (only
    /// used for the post-app-switch re-hint). The Cmd+Tab switcher HUD is
    /// a Dock-owned window — a normal full-display capture taken right
    /// after a switch catches the still-fading HUD and OmniParser turns
    /// its app icons into bogus hints. Dropping the Dock removes the HUD
    /// (and the Dock itself, which OP doesn't need) regardless of
    /// whether/when the HUD dismisses — no timing guess. Costs a fresh
    /// `SCShareableContent` query (apps list isn't cached) + re-
    /// composition; only paid on the infrequent app-switch path. (Tried
    /// `including:[focusedApp]` first for tighter isolation, but its
    /// canvas-anchoring semantics aren't clearly documented and produced
    /// misaligned crops in testing. `excludingApplications:[dock]` is a
    /// display-based filter — predictable canvas, predictable crop.)
    static func captureFocusedWindow(isolateApp: Bool = false) async -> Captured? {
        let tStart = Date()
        guard let (windowEl, pid) = focusedWindow() else {
            print("[mouseless] ScreenCapture: no focused window (AX chain returned nil)")
            return nil
        }
        guard let windowRectInAX = windowRect(windowEl) else {
            print("[mouseless] ScreenCapture: window has no AXPosition/AXSize")
            return nil
        }
        let tAX = Date()

        // Lazy permission: only ask when we actually need to capture.
        // First call without permission triggers the native TCC prompt.
        // User must grant + restart the app — there's no "wait for grant"
        // API. So this attempt fails; next trigger after restart works.
        guard CGPreflightScreenCaptureAccess() else {
            print("[mouseless] ScreenCapture: requesting Screen Recording permission")
            _ = CGRequestScreenCaptureAccess()
            return nil
        }

        do {
            // Find the SCDisplay whose frame contains the focused window.
            // SCDisplay.frame is in the same global display coordinate
            // space as AX (top-left origin, points). For multi-display
            // setups the window's display origin can be non-zero — we
            // subtract it below when computing crop offset.
            let display: SCDisplay
            let filter: SCContentFilter
            if isolateApp {
                // App-switch path: exclude the Dock process entirely.
                // The Cmd+Tab switcher HUD is a Dock-owned window, so
                // dropping the Dock app drops the HUD (and the Dock at
                // screen edge, which OP doesn't hint anyway). Keeps a
                // display-sized canvas (contentRect == display.frame),
                // so the crop math is predictable — unlike the earlier
                // `including:[focusedApp]` attempt whose contentRect
                // quirks produced a partial image with a black gutter.
                // Tradeoff: doesn't drop other-app overlays (notification
                // banners etc.) — separate problem, defer.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let d = content.displays.first(where: {
                    $0.frame.intersects(windowRectInAX)
                }) else {
                    print("[mouseless] ScreenCapture: no SCDisplay contains the focused window")
                    return nil
                }
                display = d
                if let dockApp = content.applications.first(where: {
                    $0.bundleIdentifier == "com.apple.dock"
                }) {
                    filter = SCContentFilter(display: d, excludingApplications: [dockApp], exceptingWindows: [])
                } else {
                    print("[mouseless] ScreenCapture: Dock app not found — full-display fallback")
                    filter = SCContentFilter(display: d, excludingWindows: [])
                }
            } else {
                let displays = try await cachedDisplays()
                guard let d = displays.first(where: {
                    $0.frame.intersects(windowRectInAX)
                }) else {
                    print("[mouseless] ScreenCapture: no SCDisplay contains the focused window")
                    return nil
                }
                display = d
                // Capture the full display. Empty excludingWindows means
                // "everything on screen". This reads the already-composited
                // framebuffer instead of forcing per-window re-render.
                filter = SCContentFilter(display: d, excludingWindows: [])
            }
            let tEnum = Date()

            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            // Don't capture the cursor — OmniParser doesn't need it.
            config.showsCursor = false
            let tFilter = Date()

            let displayImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let tCap = Date()

            // Crop to the focused window inside the captured display.
            // AXPosition is in the AX/global coordinate space (top-left
            // origin, points), whereas the captured image's pixel (0,0)
            // is at the captured display's **local** top-left — so we
            // subtract `display.frame.origin` (the display's global
            // origin) to convert. Crucial for multi-display setups
            // where the secondary display sits at a non-zero global
            // origin (e.g. (2992, 0)).
            //
            // (Earlier we tried `filter.contentRect.origin` thinking
            // it was the global origin. For display-based filters it's
            // actually (0,0) local — equal to display.frame.origin on
            // the primary, but not on secondaries — which silently
            // produced empty crops there. Both current filter types
            // are display-based, so `display.frame` is the right
            // reference.)
            let displayOrigin = display.frame.origin
            let cropInPoints = windowRectInAX.offsetBy(
                dx: -displayOrigin.x,
                dy: -displayOrigin.y
            )
            // Clamp to the display bounds in local coords (cropping(to:)
            // returns nil if fully out of bounds, ragged image if
            // partially).
            let displayBoundsInPoints = CGRect(
                x: 0, y: 0,
                width: display.frame.width,
                height: display.frame.height
            )
            let clampedInPoints = cropInPoints.intersection(displayBoundsInPoints)
            let cropInPixels = CGRect(
                x: floor(clampedInPoints.minX * scale),
                y: floor(clampedInPoints.minY * scale),
                width: floor(clampedInPoints.width * scale),
                height: floor(clampedInPoints.height * scale)
            )
            guard let cropped = displayImage.cropping(to: cropInPixels) else {
                print("[mouseless] ScreenCapture: crop failed (rect=\(cropInPixels) image=\(displayImage.width)×\(displayImage.height))")
                return nil
            }
            let tCrop = Date()

            let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
            print("[mouseless] ScreenCapture timings: ax=\(ms(tStart, tAX))ms enum=\(ms(tAX, tEnum))ms filter=\(ms(tEnum, tFilter))ms capture=\(ms(tFilter, tCap))ms crop=\(ms(tCap, tCrop))ms total=\(ms(tStart, tCrop))ms isolateApp=\(isolateApp) display=\(displayImage.width)×\(displayImage.height) crop=\(cropped.width)×\(cropped.height)")
            return Captured(image: cropped, screenRect: windowRectInAX)
        } catch {
            print("[mouseless] ScreenCapture failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Permission helpers (exposed for AppDelegate banner/UI)

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - Display cache
    //
    // `SCShareableContent.excludingDesktopWindows(...)` is a cross-process
    // round-trip that enumerates every window the user could see — ~50ms
    // per call. We only need the *displays* list, which changes only when
    // the user plugs/unplugs a monitor or rearranges them in Settings.
    // Cache it across calls and invalidate on screen change.

    private static var cachedDisplaysValue: [SCDisplay]?
    private static var screenChangeObserver: NSObjectProtocol?

    private static func cachedDisplays() async throws -> [SCDisplay] {
        installScreenChangeObserverIfNeeded()
        if let cached = cachedDisplaysValue {
            print("[mouseless] ScreenCapture: cache HIT (\(cached.count) displays)")
            return cached
        }
        print("[mouseless] ScreenCapture: cache MISS, querying SCShareableContent")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        cachedDisplaysValue = content.displays
        return content.displays
    }

    private static func installScreenChangeObserverIfNeeded() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Display config changed (plug, unplug, rearrange,
            // resolution swap). Drop the cached SCDisplay list so the
            // next capture re-queries SCShareableContent. We can't do
            // this on @MainActor from a notification handler closure,
            // but cachedDisplaysValue is also @MainActor; the closure
            // runs on the main queue so we can just touch it.
            MainActor.assumeIsolated {
                ScreenCapture.cachedDisplaysValue = nil
                print("[mouseless] ScreenCapture: display config changed, cache invalidated")
            }
        }
    }

    // MARK: - Debug

    /// P2-only: capture focused window and write to /tmp/mouseless-focused.png
    /// for visual inspection. Runs in a Task — does not block the caller.
    /// Strip once OmniParser integration replaces /tmp dump with actual
    /// downstream pipeline.
    static func debugCaptureToTmp() {
        Task { @MainActor in
            let t0 = Date()
            guard let captured = await captureFocusedWindow() else {
                print("[mouseless] debug capture: returned nil (see preceding log)")
                return
            }
            let image = captured.image
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

    /// Frontmost app (via NSWorkspace) → AXFocusedWindow (with fallbacks).
    /// Returns the window AXUIElement; we get the rect from AXPosition +
    /// AXSize in `windowRect(_:)`. Logs the specific failure step so we
    /// can diagnose AX-bad apps.
    ///
    /// (We used to also extract CGWindowID via the private
    /// `_AXUIElementGetWindow` API for `SCContentFilter(desktopIndependentWindow:)`,
    /// but display capture + crop doesn't need it — public APIs only now.)
    private static func focusedWindow() -> (element: AXUIElement, pid: pid_t)? {
        // Step 1: frontmost app via NSWorkspace (reliable on Electron;
        // AXFocusedApplication was not — see FocusedApp.swift).
        guard let (app, pid) = FocusedApp.current() else {
            print("[mouseless] AX step 1 (frontmost app): NSWorkspace returned nil")
            return nil
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        print("[mouseless] AX step 1 ok: pid=\(pid) bundleID=\(bundleID)")

        // Step 2: AXFocusedWindow, with fallbacks for apps that don't
        // designate a focused window (some Electron apps after Cmd+Tab,
        // apps with no key window, etc.)
        var winRef: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(
            app, "AXFocusedWindow" as CFString, &winRef
        )
        if winErr == .success, let winRaw = winRef {
            print("[mouseless] AX step 2 (AXFocusedWindow): ok")
            return (winRaw as! AXUIElement, pid)
        }
        print("[mouseless] AX step 2 (AXFocusedWindow): err=\(axErrName(winErr)) nil=\(winRef == nil) — trying fallbacks")

        // Fallback A: AXMainWindow (set on app launch, doesn't need key state)
        var mainRef: CFTypeRef?
        let mainErr = AXUIElementCopyAttributeValue(
            app, "AXMainWindow" as CFString, &mainRef
        )
        if mainErr == .success, let mainRaw = mainRef {
            print("[mouseless] AX step 2 fallback A (AXMainWindow): ok")
            return (mainRaw as! AXUIElement, pid)
        }

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
        print("[mouseless] AX step 2 fallback B (AXWindows[0]): ok, \(windows.count) windows total")
        return (first, pid)
    }

    /// Window's screen-space rect from AX attributes.
    /// AXPosition / AXSize live in global-display top-left coordinates,
    /// in points — same space SCDisplay.frame uses.
    private static func windowRect(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
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

