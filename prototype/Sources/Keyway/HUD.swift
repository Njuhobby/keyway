import Cocoa

@MainActor
final class HUD {
    static let shared = HUD()

    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    private static let height: CGFloat = 44
    private static let horizontalPadding: CGFloat = 16   // each side, inside the rounded rect
    private static let minWidth: CGFloat = 100

    private var window: NSWindow?

    func show(_ text: String) {
        ensureWindow()
        (window?.contentView as? HUDView)?.text = text
        repositionAndResize(forText: text)
        // Re-assert all-spaces membership before ordering front — after an
        // orderOut (hidden on every app/Space switch) macOS drops the
        // all-spaces registration, so a plain orderFront reattaches the
        // HUD to the OLD Space instead of following to the active one.
        // Same fix as HintOverlay.show.
        window?.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window?.orderFrontRegardless()  // never makeKeyAndOrderFront — that steals focus
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        if window != nil { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.level = .statusBar
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = HUDView(frame: w.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        window = w
    }

    /// Sizes the HUD window to fit `text` (plus padding) and re-centers
    /// it at the bottom-middle of the main screen. Called on every
    /// `show(_:)` so longer messages (e.g. `WINDOW: no resizable
    /// window`) don't truncate. A minimum width keeps short labels
    /// like `TAP` from looking jarringly small.
    private func repositionAndResize(forText text: String) {
        guard let w = window else { return }
        let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
        let newWidth = max(Self.minWidth, ceil(textWidth + 2 * Self.horizontalPadding))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrame(NSRect(x: f.midX - newWidth / 2,
                              y: f.minY + 80,
                              width: newWidth,
                              height: Self.height),
                       display: true)
        }
    }
}

@MainActor
final class HUDView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor(white: 0, alpha: 0.78).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: HUD.font,
            .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: attrs
        )
    }
}
