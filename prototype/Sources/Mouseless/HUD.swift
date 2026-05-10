import Cocoa

@MainActor
final class HUD {
    static let shared = HUD()

    private var window: NSWindow?

    func show(_ text: String) {
        ensureWindow()
        (window?.contentView as? HUDView)?.text = text
        window?.orderFrontRegardless()  // never makeKeyAndOrderFront — that steals focus
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        if window != nil { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
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
        w.contentView = view

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - 80, y: f.minY + 80))
        }
        window = w
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
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
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
