import Cocoa

@MainActor
final class HintOverlay {
    static let shared = HintOverlay()

    /// One borderless overlay window per NSScreen. macOS doesn't reliably
    /// render a single high-level window across multiple screens — the union
    /// approach silently dropped frames on screens that weren't the window's
    /// principal display. One window per screen sidesteps that.
    private var windows: [NSWindow] = []

    func show(targets: [HintTarget], typed: String) {
        ensureWindows()
        for w in windows {
            (w.contentView as? HintOverlayView)?.update(targets: targets, typed: typed)
            w.orderFrontRegardless()
        }
    }

    func hide() {
        for w in windows { w.orderOut(nil) }
    }

    private func ensureWindows() {
        if !windows.isEmpty { return }

        for screen in NSScreen.screens {
            let frame = screen.frame
            let w = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
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

    func update(targets: [HintTarget], typed: String) {
        self.targets = targets
        self.typed = typed
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
        let bg = NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 0.95)
        let labelW: CGFloat = 22
        let labelH: CGFloat = 16

        for target in targets {
            if !typed.isEmpty && !target.label.hasPrefix(typed) { continue }

            let r = target.rect
            let nsGlobalY = primaryH - (r.origin.y + r.size.height)
            let viewX = r.origin.x - winOrigin.x
            let viewY = nsGlobalY - winOrigin.y

            let isDockLabel = target.label.first?.isNumber == true

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

                // "On screen" = on this view's bounds (this single screen).
                let viewBounds = self.bounds
                let belowOnScreen = viewBounds.intersects(belowRect)
                let aboveOnScreen = viewBounds.intersects(aboveRect)

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

            bg.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
            tail?.fill()

            // Draw the label text. Center for Dock badge, left-align for bubble.
            let typedPart = String(target.label.prefix(typed.count))
            let restPart = String(target.label.dropFirst(typed.count))
            let typedSize = (typedPart as NSString).size(withAttributes: attrsDim)
            let restSize = (restPart as NSString).size(withAttributes: attrsBlack)
            let totalW = typedSize.width + restSize.width

            var textX: CGFloat
            let textY: CGFloat
            if isDockLabel {
                textX = fillRect.midX - totalW / 2
                textY = fillRect.midY - typedSize.height / 2 + 1
            } else {
                textX = fillRect.minX + 3
                textY = fillRect.minY + 1
            }
            (typedPart as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrsDim)
            textX += typedSize.width
            (restPart as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrsBlack)
        }
    }
}
