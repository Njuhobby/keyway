import Cocoa

/// Border + edge-handle visualization for `.window` mode. Mirrors
/// `HintOverlay` / `ScrollOverlay`'s per-screen borderless-window
/// approach: one transparent NSWindow per `NSScreen`, each draws the
/// bits of the visualization that fall on its screen.
///
/// Each tick `WindowController` calls `update(rect:)` with the focused
/// window's current AX rect; this redraws:
///   - **Blue solid border** (3pt) around the rect.
///   - **Four "chip"s** at edge midpoints, just outside the border:
///       top    `↑k` / bottom `↓j` / left `←h` / right `→l`
///     A chip is **skipped** if it can't fit fully on any screen (e.g.
///     window touching the screen top → top chip would clip; per user
///     spec we just don't draw it rather than show a half chip).
///
/// Corners aren't labeled — they're hjkl combinations, the user knows.
@MainActor
final class WindowOpOverlay {
    static let shared = WindowOpOverlay()
    private init() {}

    private var windows: [NSWindow] = []

    /// `withChips: true` (default, for WINDOW resize): draws the four
    /// edge labels `↑k / ↓j / ←h / →l`. `false` (for WINDOW MOVE):
    /// just the blue border — hjkl in MOVE means "move the window in
    /// that direction", which doesn't bind to a specific edge, so
    /// border-anchored chips would suggest the wrong mental model.
    func show(rect: CGRect, withChips: Bool = true) {
        ensureWindows()
        for w in windows {
            (w.contentView as? WindowOpOverlayView)?.update(rect: rect, withChips: withChips)
            w.orderFrontRegardless()
        }
    }

    func update(rect: CGRect) {
        for w in windows {
            (w.contentView as? WindowOpOverlayView)?.update(rect: rect)
        }
    }

    func hide() {
        for w in windows { w.orderOut(nil) }
    }

    private func ensureWindows() {
        if !windows.isEmpty { return }
        for screen in NSScreen.screens {
            let f = screen.frame
            let w = NSWindow(contentRect: f, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = .statusBar
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = WindowOpOverlayView(frame: NSRect(origin: .zero, size: f.size))
            windows.append(w)
        }
    }
}

@MainActor
final class WindowOpOverlayView: NSView {
    private var axRect: CGRect = .zero
    private var showChips: Bool = true

    /// `withChips: nil` keeps the previous setting (used by tick-update
    /// from `show(rect:)` without `withChips:`). Pass `true`/`false`
    /// explicitly only when switching modes (show entry).
    func update(rect: CGRect, withChips: Bool? = nil) {
        axRect = rect
        if let withChips = withChips { showChips = withChips }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let primary = NSScreen.screens.first, let win = self.window else { return }
        let primaryH = primary.frame.height
        let winOrigin = win.frame.origin

        // AX (top-left global) → view-local (bottom-left of this NSWindow).
        let nsGlobalY = primaryH - (axRect.origin.y + axRect.size.height)
        let viewRect = NSRect(
            x: axRect.origin.x - winOrigin.x,
            y: nsGlobalY - winOrigin.y,
            width: axRect.size.width,
            height: axRect.size.height
        )

        // Bail if this screen doesn't see the window at all (multi-display
        // case: only the relevant screen's view draws anything).
        guard bounds.intersects(viewRect) else { return }

        let blue = NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)

        // Solid blue border.
        blue.setStroke()
        let path = NSBezierPath(rect: viewRect)
        path.lineWidth = 3
        path.stroke()

        // Four edge chips (skip any that don't fit fully on this screen).
        // MOVE mode passes `withChips: false` — border only.
        if showChips {
            drawChip(text: "↑k", side: .top,    of: viewRect, blue: blue)
            drawChip(text: "↓j", side: .bottom, of: viewRect, blue: blue)
            drawChip(text: "←h", side: .left,   of: viewRect, blue: blue)
            drawChip(text: "→l", side: .right,  of: viewRect, blue: blue)
        }
    }

    private enum Side { case top, bottom, left, right }

    private func drawChip(text: String, side: Side, of viewRect: NSRect, blue: NSColor) {
        let chipW: CGFloat = 32
        let chipH: CGFloat = 22
        let gap: CGFloat = 8
        let chipRect: NSRect
        switch side {
        case .top:    // above the window's top edge (high Y in NS coords)
            chipRect = NSRect(x: viewRect.midX - chipW/2,
                              y: viewRect.maxY + gap,
                              width: chipW, height: chipH)
        case .bottom: // below the window's bottom edge (low Y in NS)
            chipRect = NSRect(x: viewRect.midX - chipW/2,
                              y: viewRect.minY - gap - chipH,
                              width: chipW, height: chipH)
        case .left:
            chipRect = NSRect(x: viewRect.minX - gap - chipW,
                              y: viewRect.midY - chipH/2,
                              width: chipW, height: chipH)
        case .right:
            chipRect = NSRect(x: viewRect.maxX + gap,
                              y: viewRect.midY - chipH/2,
                              width: chipW, height: chipH)
        }
        // Per user spec: if the chip would draw outside the screen,
        // don't draw it at all (skip rather than clip).
        guard bounds.contains(chipRect) else { return }

        blue.setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: chipRect.midX - sz.width / 2,
                           y: chipRect.midY - sz.height / 2),
               withAttributes: attrs)
    }
}
