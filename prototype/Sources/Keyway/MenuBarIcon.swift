import Cocoa

/// The Keyway menu-bar mark — a key ring joined to a directional blade
/// ("key + way"). Drawn as a monochrome *template* image so the system
/// auto-tints it for light/dark menu bars. Vector-drawn (no bundled asset)
/// so it stays crisp at any backing scale.
enum MenuBarIcon {
    /// The brand mark, sized for the menu bar (~15pt tall).
    static func statusImage() -> NSImage {
        // Mark authored in a 100x100 box; this is its tight bounding box.
        let bbox = NSRect(x: 21, y: 29, width: 64, height: 26)
        let target = NSSize(width: 36, height: 15)
        let pad: CGFloat = 1
        let s = min((target.width - 2 * pad) / bbox.width,
                    (target.height - 2 * pad) / bbox.height)

        let img = NSImage(size: target, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let drawnW = bbox.width * s, drawnH = bbox.height * s
            ctx.translateBy(x: (target.width - drawnW) / 2 - bbox.minX * s,
                            y: (target.height - drawnH) / 2 - bbox.minY * s)
            ctx.scaleBy(x: s, y: s)
            NSColor.black.setFill()

            // Ring bow: outer circle with an inner hole (even-odd).
            let ring = NSBezierPath()
            ring.windingRule = .evenOdd
            ring.appendOval(in: NSRect(x: 21, y: 29, width: 26, height: 26))
            ring.appendOval(in: NSRect(x: 28, y: 36, width: 12, height: 12))
            ring.fill()

            // Blade ending in a rightward chevron — the "way".
            let blade = NSBezierPath()
            blade.move(to: NSPoint(x: 46, y: 39))
            blade.line(to: NSPoint(x: 68, y: 39))
            blade.line(to: NSPoint(x: 68, y: 33))
            blade.line(to: NSPoint(x: 85, y: 42))
            blade.line(to: NSPoint(x: 68, y: 51))
            blade.line(to: NSPoint(x: 68, y: 45))
            blade.line(to: NSPoint(x: 46, y: 45))
            blade.close()
            blade.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
