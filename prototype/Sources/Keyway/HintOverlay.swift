import Cocoa

@MainActor
final class HintOverlay {
    static let shared = HintOverlay()

    /// One borderless overlay window per NSScreen. macOS doesn't reliably
    /// render a single high-level window across multiple screens — the union
    /// approach silently dropped frames on screens that weren't the window's
    /// principal display. One window per screen sidesteps that.
    private var windows: [NSWindow] = []
    /// The screen frames `windows` were built for. When the display
    /// configuration changes (lid close, monitor (dis)connect, resolution
    /// change) the cached per-screen windows are sized/positioned for the
    /// OLD layout — they no longer cover the new screens and the AX→view
    /// coordinate math (which uses `NSScreen.screens.first` + each
    /// window's origin) goes stale, so hints render clipped / offset until
    /// a restart. Comparing against this on every `show` lets us rebuild.
    private var builtForScreens: [CGRect] = []

    func show(targets: [HintTarget], typed: String, moveArmed: Bool = false) {
        ensureWindows()
        for w in windows {
            (w.contentView as? HintOverlayView)?.update(targets: targets, typed: typed,
                                                        moveArmed: moveArmed)
            w.orderFrontRegardless()
        }
    }

    /// Hide by clearing the labels, NOT by ordering the window out.
    ///
    /// `orderOut` drops the window's all-spaces registration in the window
    /// server. The next `orderFront` can then re-attach it to whichever
    /// Space it was last shown on rather than the one you're now on, so
    /// hints render on the wrong Space. Whether that happens is a race
    /// (intermittent to trigger); once it does, the window is stuck there —
    /// the old `isOnActiveSpace`-gated self-heal couldn't reliably detect
    /// the stuck state (`isOnActiveSpace` is unreliable for a
    /// canJoinAllSpaces window), so re-entering hint mode never recovered.
    ///
    /// Keeping the window resident (transparent, click-through, just
    /// emptied) means it never loses all-spaces membership, so it always
    /// follows you. An empty overlay draws nothing — no visual or
    /// screen-capture effect between sessions.
    func hide() {
        for w in windows {
            (w.contentView as? HintOverlayView)?.update(targets: [], typed: "", moveArmed: false)
        }
    }

    private func ensureWindows() {
        let current = NSScreen.screens.map { $0.frame }
        // Already built for exactly this layout → reuse.
        if !windows.isEmpty && current == builtForScreens { return }
        // Display config changed (or first run): tear down the stale
        // windows and rebuild for the current screens.
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        builtForScreens = current

        for screen in NSScreen.screens {
            let frame = screen.frame
            let w = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // Level 102 (CGWindowLevel "overlay") — ABOVE dropdown /
            // contextual menus (.popUpMenu = 101). Necessary because
            // hint labels for AXMenuItem are drawn at the top-left
            // inside each menu item's rect; at the natural z-order
            // (.statusBar = 25) the dropdown's own background fills
            // that rect and visually covers the label. Raising above
            // .popUpMenu lets the small label squares (overlay
            // otherwise transparent) float above the menu while the
            // menu's actual text + icons still show through everywhere
            // except the label rects. Trade-off: hint labels will
            // also draw above modal alerts (level 8) and other normal
            // windows — which is what the user wants in TAP mode
            // anyway (hint-click the alert's buttons). The level
            // stays below assistive-tech windows (1500) and the
            // screen saver (1000).
            w.level = NSWindow.Level(rawValue: 102)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = HintOverlayView(frame: NSRect(origin: .zero, size: frame.size))
            windows.append(w)
        }
    }
}

@MainActor
final class HintOverlayView: NSView {
    private var targets: [HintTarget] = []
    private var typed: String = ""
    private var moveArmed: Bool = false

    func update(targets: [HintTarget], typed: String, moveArmed: Bool = false) {
        self.targets = targets
        self.typed = typed
        self.moveArmed = moveArmed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // This view covers exactly ONE screen. Convert AX (top-left,
        // origin = top-left of primary screen) into our view's local coords.
        guard let primary = NSScreen.screens.first,
              let win = self.window else { return }
        let primaryH = primary.frame.height
        let winOrigin = win.frame.origin   // this is OUR screen's NSScreen origin

        let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let attrsBlack: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.black,
        ]
        let attrsDim: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.30),
        ]
        // Default hint chip is saturated yellow. When move-armed (`'`
        // prefix), use a paler yellow so the user can see at a glance
        // that the next pick warps the cursor rather than clicking.
        let bg = moveArmed
            ? NSColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 0.95)
            : NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.95)
        let labelW: CGFloat = 22
        let labelH: CGFloat = 16

        // Pass 1: compute each visible label's placement; pass 2 (after
        // the loop) de-collides; pass 3 draws.
        var placed: [Placed] = []

        for target in targets {
            if !typed.isEmpty && !target.label.hasPrefix(typed) { continue }

            let r = target.rect
            let nsGlobalY = primaryH - (r.origin.y + r.size.height)
            let viewX = r.origin.x - winOrigin.x
            let viewY = nsGlobalY - winOrigin.y

            let isDockLabel = target.label.first?.isNumber == true

            // Inside-top-left placement (no tail) when the target rect
            // is large enough to accommodate the badge — applies to
            // BOTH AX and OmniParser targets.
            //
            // Threshold: 30pt × 16pt. Horizontal needs 4pt padding on
            // each side so the badge doesn't touch the rect's left
            // edge. Vertical needs zero padding — many AX elements
            // (date / size cells in Finder list view) have rects
            // sized tight to their text glyphs (~14-16pt tall), so
            // any positive Y padding rejects them and they fall back
            // to speech-bubble placement (which is exactly the
            // ambiguous "label floating between rows" case the inset
            // path was built to fix). Label flush to rect's top edge
            // is acceptable — content below the label is still
            // readable because text usually doesn't start at the
            // absolute top pixel.
            //
            // The original "speech bubble + tail" floats the badge in
            // the gap between rects, ambiguous when they're packed
            // tightly. Inside placement makes ownership unambiguous
            // and drops the tiny tail entirely.
            let insidePadX: CGFloat = 4
            let fitsInside = target.rect.width >= labelW + 2 * insidePadX
                && target.rect.height >= labelH

            let fillRect: NSRect
            var tail: NSBezierPath? = nil

            if isDockLabel {
                // Dock: bubble (square + triangle) on the OUTSIDE of the icon,
                // pointing toward it. Position depends on Dock orientation.
                let badgeSize: CGFloat = 20
                let iconGap: CGFloat = 1
                let tailBase: CGFloat = 8
                let tailTip: CGFloat = 5

                let dockOrientation = UserDefaults(suiteName: "com.apple.dock")?
                    .string(forKey: "orientation") ?? "bottom"

                let badgeRect: NSRect
                let p = NSBezierPath()

                switch dockOrientation {
                case "left":
                    // Icon on left edge → badge on its right, tail points LEFT.
                    let tipX = viewX + r.size.width + iconGap
                    badgeRect = NSRect(
                        x: tipX + tailTip,
                        y: viewY + r.size.height / 2 - badgeSize / 2,
                        width: badgeSize,
                        height: badgeSize
                    )
                    p.move(to: NSPoint(x: badgeRect.minX, y: badgeRect.midY + tailBase / 2))
                    p.line(to: NSPoint(x: tipX, y: badgeRect.midY))
                    p.line(to: NSPoint(x: badgeRect.minX, y: badgeRect.midY - tailBase / 2))

                case "right":
                    // Icon on right edge → badge on its left, tail points RIGHT.
                    let tipX = viewX - iconGap
                    badgeRect = NSRect(
                        x: tipX - tailTip - badgeSize,
                        y: viewY + r.size.height / 2 - badgeSize / 2,
                        width: badgeSize,
                        height: badgeSize
                    )
                    p.move(to: NSPoint(x: badgeRect.maxX, y: badgeRect.midY - tailBase / 2))
                    p.line(to: NSPoint(x: tipX, y: badgeRect.midY))
                    p.line(to: NSPoint(x: badgeRect.maxX, y: badgeRect.midY + tailBase / 2))

                default:  // "bottom" or unknown
                    // Icon at bottom → badge above it, tail points DOWN.
                    let tipY = viewY + r.size.height + iconGap
                    badgeRect = NSRect(
                        x: viewX + r.size.width / 2 - badgeSize / 2,
                        y: tipY + tailTip,
                        width: badgeSize,
                        height: badgeSize
                    )
                    p.move(to: NSPoint(x: badgeRect.midX - tailBase / 2, y: badgeRect.minY))
                    p.line(to: NSPoint(x: badgeRect.midX, y: tipY))
                    p.line(to: NSPoint(x: badgeRect.midX + tailBase / 2, y: badgeRect.minY))
                }
                p.close()

                fillRect = badgeRect
                tail = p
            } else if fitsInside {
                // Big-enough target (AX or OP): top-left INSIDE with
                // 4pt horizontal padding, zero vertical (badge flush
                // to rect's top edge). NSView coords have Y going up,
                // so the rect's top edge is at `viewY + r.size.height`
                // and the label rect's bottom-left is `top - labelH`.
                fillRect = NSRect(
                    x: viewX + insidePadX,
                    y: viewY + r.size.height - labelH,
                    width: labelW,
                    height: labelH
                )
                // tail stays nil — badge inside the rect is self-evident,
                // no pointer needed.
            } else {
                // Non-Dock: speech-bubble below element, fall back to above
                // if below would land off any screen.
                let tailH: CGFloat = 4
                let tailW: CGFloat = 8
                let belowRect = NSRect(
                    x: viewX,
                    y: viewY - tailH - labelH,
                    width: labelW,
                    height: labelH
                )
                let aboveRect = NSRect(
                    x: viewX,
                    y: viewY + r.size.height + tailH,
                    width: labelW,
                    height: labelH
                )

                // "Fits on screen" = badge is fully contained in this view.
                let viewBounds = self.bounds
                let belowOnScreen = viewBounds.contains(belowRect)
                let aboveOnScreen = viewBounds.contains(aboveRect)

                let tailPointsUp: Bool
                if belowOnScreen {
                    fillRect = belowRect
                    tailPointsUp = true
                } else if aboveOnScreen {
                    fillRect = aboveRect
                    tailPointsUp = false
                } else {
                    // Element isn't on this screen at all; skip drawing.
                    continue
                }

                let p = NSBezierPath()
                let tailLeftX = fillRect.minX + 4
                if tailPointsUp {
                    let tailBaseY = fillRect.maxY
                    p.move(to: NSPoint(x: tailLeftX, y: tailBaseY))
                    p.line(to: NSPoint(x: tailLeftX + tailW / 2, y: tailBaseY + tailH))
                    p.line(to: NSPoint(x: tailLeftX + tailW, y: tailBaseY))
                } else {
                    let tailBaseY = fillRect.minY
                    p.move(to: NSPoint(x: tailLeftX, y: tailBaseY))
                    p.line(to: NSPoint(x: tailLeftX + tailW / 2, y: tailBaseY - tailH))
                    p.line(to: NSPoint(x: tailLeftX + tailW, y: tailBaseY))
                }
                p.close()
                tail = p
            }

            // Skip if this target's label rect doesn't intersect this view.
            if !self.bounds.intersects(fillRect) { continue }

            // Don't draw yet — collect for a de-collision pass below.
            placed.append(Placed(rect: fillRect, tail: tail,
                                 isDock: isDockLabel, label: target.label))
        }

        // ---- De-collision pass ----
        // Each label rect was computed independently, so on dense pages
        // (web toolbars, icon grids, nav bars) they overlap and become
        // unreadable. The user reads the label TEXT then types it, so an
        // occluded label is useless. Greedily nudge each colliding label
        // to the nearest free slot (small offsets, stays near its
        // element). A nudged label drops its tail (the connector would
        // point wrong); the badge near the element is enough. Last
        // resort (no free slot within budget): draw at preferred spot,
        // accept the overlap. Dock labels are left in place (they live
        // outside the icon grid and rarely collide; nudging them off
        // their tail looks worse).
        var occupied: [NSRect] = []
        for i in placed.indices {
            if placed[i].isDock { occupied.append(placed[i].rect); continue }
            let free = Self.nudgeToFree(placed[i].rect, avoiding: occupied,
                                        within: self.bounds,
                                        stepX: labelW, stepY: labelH)
            if free != placed[i].rect {
                placed[i].rect = free
                placed[i].tail = nil   // moved → connector would mislead
            }
            occupied.append(placed[i].rect)
        }

        // ---- Draw pass ----
        for p in placed {
            bg.setFill()
            NSBezierPath(roundedRect: p.rect, xRadius: 3, yRadius: 3).fill()
            p.tail?.fill()

            let typedPart = String(p.label.prefix(typed.count))
            let restPart = String(p.label.dropFirst(typed.count))
            let typedSize = (typedPart as NSString).size(withAttributes: attrsDim)
            let restSize = (restPart as NSString).size(withAttributes: attrsBlack)
            let totalW = typedSize.width + restSize.width

            var textX: CGFloat
            let textY: CGFloat
            if p.isDock {
                textX = p.rect.midX - totalW / 2
                textY = p.rect.midY - typedSize.height / 2 + 1
            } else {
                textX = p.rect.minX + 3
                textY = p.rect.minY + 1
            }
            (typedPart as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrsDim)
            textX += typedSize.width
            (restPart as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrsBlack)
        }
    }

    /// A computed label placement, collected in pass 1 and adjusted by
    /// the de-collision pass before drawing.
    private struct Placed {
        var rect: NSRect
        var tail: NSBezierPath?
        let isDock: Bool
        let label: String
    }

    /// Greedy de-collision: if `preferred` overlaps any `avoiding` rect,
    /// search a grid of small offsets (ordered nearest-first) for a slot
    /// that's free AND fully inside `bounds`. Returns the chosen rect, or
    /// `preferred` if nothing free within the search budget (accept the
    /// overlap rather than push the label far from its element).
    private static func nudgeToFree(_ preferred: NSRect,
                                    avoiding: [NSRect],
                                    within bounds: NSRect,
                                    stepX: CGFloat,
                                    stepY: CGFloat) -> NSRect {
        func collides(_ r: NSRect) -> Bool {
            // 1pt gap so adjacent labels don't visually touch.
            let g = r.insetBy(dx: -1, dy: -1)
            for o in avoiding where o.intersects(g) { return true }
            return false
        }
        if !collides(preferred) { return preferred }

        // Candidate offsets out to radius 3 in each axis, ordered by
        // distance from origin (nearest free slot wins). Skip (0,0)
        // (already known to collide).
        let radius = 3
        var offsets: [(CGFloat, CGFloat)] = []
        for dy in -radius...radius {
            for dx in -radius...radius {
                if dx == 0 && dy == 0 { continue }
                offsets.append((CGFloat(dx) * stepX, CGFloat(dy) * stepY))
            }
        }
        offsets.sort { hypot($0.0, $0.1) < hypot($1.0, $1.1) }

        for (dx, dy) in offsets {
            let cand = preferred.offsetBy(dx: dx, dy: dy)
            if bounds.contains(cand) && !collides(cand) { return cand }
        }
        return preferred   // give up — overlap is the lesser evil vs. far drift
    }
}
