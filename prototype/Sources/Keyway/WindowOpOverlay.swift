import Cocoa

/// Border + edge-handle visualization for `.window` mode. Mirrors
/// `HintOverlay` / `ScrollOverlay`'s per-screen borderless-window
/// approach: one transparent NSWindow per `NSScreen`, each draws the
/// bits of the visualization that fall on its screen.
///
/// Each tick `WindowController` calls `update(rect:)` with the focused
/// window's current AX rect; this redraws:
///   - **Blue solid border** (3pt) around the rect.
///   - **Four two-line "chip"s** at edge midpoints, just outside the
///     border. Each chip shows BOTH bindings for that edge — single
///     press expands, double-tap shrinks:
///       top    `↑k / ↓kk` (k grows top; kk shrinks top)
///       bottom `↓j / ↑jj` (j grows bottom; jj shrinks bottom)
///       left   `←h / →hh` (h grows left; hh shrinks left)
///       right  `→l / ←ll` (l grows right; ll shrinks right)
///     A chip is **skipped** if it can't fit fully on any screen (e.g.
///     window touching the screen top → top chip would clip; per user
///     spec we just don't draw it rather than show a half chip).
///
/// Corners aren't labeled — they're hjkl combinations, the user knows.
/// The reverse hint is on the chip itself (not the HUD) because the
/// user is already looking AT the window border while resizing — the
/// HUD at screen-bottom is too far from the attention focus to be
/// glanceable. Double-tap-for-reverse (rather than Shift-for-reverse,
/// the earlier design) keeps Shift free for "accelerate" — the
/// universal modifier convention across TAP / SCROLL / MOVE.
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

    /// Hide by clearing the rect (a zero rect intersects nothing, so the
    /// view draws nothing), NOT by ordering the window out. `orderOut` drops
    /// the window's all-spaces registration, so the next show can land on the
    /// Space it was last on instead of the active one. See `HintOverlay.hide`.
    func hide() {
        for w in windows {
            (w.contentView as? WindowOpOverlayView)?.update(rect: .zero)
        }
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

    // Cached fonts. Switched away from
    // `monospacedSystemFont(ofSize:weight:)` after a crash in
    // CoreText's `TAttributes::ApplyFont`: that API can return nil
    // for certain (size, weight) pairs on some macOS builds despite a
    // non-optional Swift signature; the Swift bridge force-casts the
    // nil to NSFont, the attributes dict ends up with a nil value at
    // `.font`, and NSStringDrawing throws "attempt to insert nil
    // object from objects[0]" when CoreText tries to copy the dict.
    // `systemFont(ofSize:weight:)` (regular SF, not Mono) is more
    // robust here and renders the arrow glyphs (↑ ↓ ← →) cleanly
    // anyway. Cached at static-let so they're created once at first
    // use, not rebuilt per chip per redraw (the previous code
    // re-constructed the attribute dicts on every tick × 4 chips,
    // which is the path that hit the flaky monospacedSystemFont
    // call most often).
    private static let bareFont: NSFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let reverseFont: NSFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let dimWhite: NSColor = NSColor.white.withAlphaComponent(0.85)

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
        // Each chip = bare key on line 1, double-tap reverse on line 2.
        if showChips {
            drawChip(bare: "↑k", reverse: "↓kk", side: .top,    of: viewRect, blue: blue)
            drawChip(bare: "↓j", reverse: "↑jj", side: .bottom, of: viewRect, blue: blue)
            drawChip(bare: "←h", reverse: "→hh", side: .left,   of: viewRect, blue: blue)
            drawChip(bare: "→l", reverse: "←ll", side: .right,  of: viewRect, blue: blue)
        }
    }

    private enum Side { case top, bottom, left, right }

    private func drawChip(bare: String, reverse: String, side: Side, of viewRect: NSRect, blue: NSColor) {
        // Two-line chip: each line is ≤3 chars in 13pt mono bold —
        // fits comfortably in 44pt width. Height carries two text
        // lines + a small gap.
        let chipW: CGFloat = 44
        let chipH: CGFloat = 36
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
        NSBezierPath(roundedRect: chipRect, xRadius: 5, yRadius: 5).fill()

        // Line 1 (top): bare key + arrow, larger / bolder weight.
        // Line 2 (bottom): double-tap reverse, slightly smaller +
        // dimmer to visually subordinate it to the primary binding.
        // Fonts are file-scope cached static-lets — see the comment
        // there for why we don't construct them per-draw.
        let bareAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.bareFont,
            .foregroundColor: NSColor.white,
        ]
        let reverseAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.reverseFont,
            .foregroundColor: Self.dimWhite,
        ]
        let bareStr = bare as NSString
        let bareSz = bareStr.size(withAttributes: bareAttrs)
        let reverseStr = reverse as NSString
        let reverseSz = reverseStr.size(withAttributes: reverseAttrs)

        // Stack vertically: bare on top half, reverse on bottom half.
        let topY = chipRect.midY + 1                              // upper half center
        let botY = chipRect.midY - reverseSz.height - 1           // lower half center
        bareStr.draw(at: NSPoint(x: chipRect.midX - bareSz.width / 2, y: topY),
                     withAttributes: bareAttrs)
        reverseStr.draw(at: NSPoint(x: chipRect.midX - reverseSz.width / 2, y: botY),
                        withAttributes: reverseAttrs)
    }
}
