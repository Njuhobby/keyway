import Cocoa

/// Draws the SCROLL-mode area picker: a highlighted border around each
/// detected scroll area + a blue numbered badge at its top-left. The
/// selected area is emphasized. Mirrors HintOverlay's per-screen
/// borderless-window approach.
/// See `specs/scroll-mode-design.md` §5.
@MainActor
final class ScrollOverlay {
    static let shared = ScrollOverlay()

    private var windows: [NSWindow] = []

    /// Show the overlay for `areas`, emphasizing `selected` (index into
    /// `areas`). Number badges are 1-based.
    func show(areas: [CGRect], selected: Int) {
        ensureWindows()
        for w in windows {
            (w.contentView as? ScrollOverlayView)?.update(areas: areas, selected: selected)
            w.orderFrontRegardless()
        }
    }

    /// Hide by clearing the areas (the view draws nothing when empty), NOT
    /// by ordering the window out. `orderOut` drops the window's all-spaces
    /// registration, so the next show can land on the Space it was last on
    /// instead of the active one. See `HintOverlay.hide` for the full story.
    func hide() {
        for w in windows {
            (w.contentView as? ScrollOverlayView)?.update(areas: [], selected: 0)
        }
    }

    private func ensureWindows() {
        if !windows.isEmpty { return }
        for screen in NSScreen.screens {
            let frame = screen.frame
            let w = NSWindow(contentRect: frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.level = .statusBar
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = ScrollOverlayView(frame: NSRect(origin: .zero, size: frame.size))
            windows.append(w)
        }
    }
}

@MainActor
final class ScrollOverlayView: NSView {
    private var areas: [CGRect] = []
    private var selected: Int = 0

    func update(areas: [CGRect], selected: Int) {
        self.areas = areas
        self.selected = selected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let primary = NSScreen.screens.first,
              let win = self.window else { return }
        let primaryH = primary.frame.height
        let winOrigin = win.frame.origin

        let labelFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white,
        ]
        let blue = NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)

        for (i, axRect) in areas.enumerated() {
            // AX (top-left, global) → this view's local (bottom-left) coords.
            let nsGlobalY = primaryH - (axRect.origin.y + axRect.size.height)
            let viewRect = NSRect(
                x: axRect.origin.x - winOrigin.x,
                y: nsGlobalY - winOrigin.y,
                width: axRect.size.width,
                height: axRect.size.height
            )
            if !self.bounds.intersects(viewRect) { continue }

            let isSelected = (i == selected)

            // Soft glow outline (Homerow-style) instead of a hard border:
            // a thin rounded stroke with a blurred shadow of the same
            // color blooms into a glow on both sides of the line. The
            // selected area glows brighter/wider; others are faint.
            let rounded = NSBezierPath(roundedRect: viewRect.insetBy(dx: 2, dy: 2),
                                       xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = blue.withAlphaComponent(isSelected ? 0.9 : 0.35)
            glow.shadowBlurRadius = isSelected ? 16 : 8
            glow.shadowOffset = .zero
            glow.set()
            blue.withAlphaComponent(isSelected ? 0.9 : 0.4).setStroke()
            rounded.lineWidth = isSelected ? 2 : 1.5
            rounded.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // Numbered badge at the area's top-left (high Y = top edge in
            // this flipped view). No shadow — keep it crisp.
            let badgeW: CGFloat = 22
            let badgeH: CGFloat = 18
            let badgeRect = NSRect(
                x: viewRect.minX + 2,
                y: viewRect.maxY - badgeH - 2,
                width: badgeW, height: badgeH
            )
            blue.withAlphaComponent(isSelected ? 0.95 : 0.6).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()

            let num = "\(i + 1)" as NSString
            let sz = num.size(withAttributes: textAttrs)
            num.draw(at: NSPoint(x: badgeRect.midX - sz.width / 2,
                                 y: badgeRect.midY - sz.height / 2),
                     withAttributes: textAttrs)
        }
    }
}
