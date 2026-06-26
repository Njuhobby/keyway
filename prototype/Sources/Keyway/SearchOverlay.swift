import Cocoa

/// Draws the TAP `/`-search "picking" sub-state: a translucent yellow
/// highlight box around each matched substring + a hint-style label
/// chip next to it (`a`, `as`, …). Same per-NSScreen borderless
/// transparent NSWindow approach as `HintOverlay` / `ScrollOverlay` /
/// `WindowOpOverlay`.
///
/// Match rects come from the search OCR pass in AX global screen
/// coords; this view flips them into NS bottom-left coords for
/// drawing (same pattern as other overlays). The TAP hint overlay
/// is hidden while search is active, so the label pool can be
/// reused for matches without visual collision.
@MainActor
final class SearchOverlay {
    static let shared = SearchOverlay()
    private init() {}

    struct Match: Sendable {
        let label: String
        let rect: CGRect    // AX screen coords (top-left origin)
    }

    private var windows: [NSWindow] = []

    func show(matches: [Match], typed: String) {
        ensureWindows()
        for w in windows {
            (w.contentView as? SearchOverlayView)?.update(matches: matches, typed: typed)
            w.orderFrontRegardless()
        }
    }

    /// Update the prefix the user has typed for label selection — the
    /// view dims labels whose prefix doesn't match (visual feedback
    /// while the user is committing a label character by character).
    func updateTyped(_ typed: String) {
        for w in windows {
            (w.contentView as? SearchOverlayView)?.updateTyped(typed)
        }
    }

    /// Hide by clearing the matches (the view draws nothing when empty), NOT
    /// by ordering the window out. `orderOut` drops the window's all-spaces
    /// registration, so the next show can land on the Space it was last on
    /// instead of the active one. See `HintOverlay.hide` for the full story.
    func hide() {
        for w in windows {
            (w.contentView as? SearchOverlayView)?.update(matches: [], typed: "")
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
            w.contentView = SearchOverlayView(frame: NSRect(origin: .zero, size: f.size))
            windows.append(w)
        }
    }
}

@MainActor
final class SearchOverlayView: NSView {
    private var matches: [SearchOverlay.Match] = []
    private var typed: String = ""

    func update(matches: [SearchOverlay.Match], typed: String) {
        self.matches = matches
        self.typed = typed
        needsDisplay = true
    }

    func updateTyped(_ typed: String) {
        self.typed = typed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let primary = NSScreen.screens.first, let win = self.window else { return }
        let primaryH = primary.frame.height
        let winOrigin = win.frame.origin

        let highlightFill = NSColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 0.35)   // yellow highlight
        let highlightStroke = NSColor(red: 1.0, green: 0.70, blue: 0.0, alpha: 0.85)
        let chipFill = NSColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 0.95)
        let chipText = NSColor.black

        let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: chipText,
        ]
        let chipPadding: CGFloat = 4
        let chipHeight: CGFloat = 18

        for match in matches {
            // AX (top-left, global) → view-local (bottom-left).
            let nsGlobalY = primaryH - (match.rect.origin.y + match.rect.size.height)
            let viewRect = NSRect(
                x: match.rect.origin.x - winOrigin.x,
                y: nsGlobalY - winOrigin.y,
                width: match.rect.size.width,
                height: match.rect.size.height
            )
            guard bounds.intersects(viewRect) else { continue }

            // Match's label is "active" only if it prefix-matches what
            // the user has typed so far. Non-matching ones dim out so
            // the user sees the remaining candidates.
            let isCandidate = typed.isEmpty || match.label.hasPrefix(typed)
            let fillAlpha: CGFloat = isCandidate ? 1.0 : 0.25

            // 1. Highlight rectangle around the matched text.
            highlightFill.withAlphaComponent(0.35 * fillAlpha).setFill()
            highlightStroke.withAlphaComponent(0.85 * fillAlpha).setStroke()
            let highlight = NSBezierPath(roundedRect: viewRect.insetBy(dx: -2, dy: -2),
                                         xRadius: 3, yRadius: 3)
            highlight.fill()
            highlight.lineWidth = 1.5
            highlight.stroke()

            // 2. Label chip just to the LEFT of the match (so the
            //    user's eye reads "label" then "text" naturally).
            //    If the match is near the screen-left edge and the
            //    chip would clip, place it inside-left instead.
            let labelStr = match.label as NSString
            let labelSize = labelStr.size(withAttributes: textAttrs)
            let chipWidth = ceil(labelSize.width) + 2 * chipPadding
            let chipGap: CGFloat = 4
            var chipX = viewRect.minX - chipGap - chipWidth
            if chipX < bounds.minX + 2 {
                // Fallback: chip inside-left (overlays the start of
                // the highlighted text). Visible but slightly more
                // crowded.
                chipX = viewRect.minX + 2
            }
            let chipRect = NSRect(
                x: chipX,
                y: viewRect.midY - chipHeight / 2,
                width: chipWidth,
                height: chipHeight
            )
            chipFill.withAlphaComponent(0.95 * fillAlpha).setFill()
            NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4).fill()
            // Already-typed prefix is greyed; remaining chars are black.
            let prefix = typed.isEmpty ? "" : String(match.label.prefix(typed.count))
            let suffix = String(match.label.dropFirst(typed.count))
            var drawX = chipRect.minX + chipPadding
            if !prefix.isEmpty {
                let dimAttrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: chipText.withAlphaComponent(0.45),
                ]
                let ps = prefix as NSString
                ps.draw(at: NSPoint(x: drawX, y: chipRect.midY - labelSize.height / 2),
                        withAttributes: dimAttrs)
                drawX += ceil(ps.size(withAttributes: dimAttrs).width)
            }
            let ss = suffix as NSString
            ss.draw(at: NSPoint(x: drawX, y: chipRect.midY - labelSize.height / 2),
                    withAttributes: textAttrs)
        }
    }
}
