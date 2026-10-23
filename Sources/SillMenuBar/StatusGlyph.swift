import AppKit

/// The status item's image: Oriel's bay window (Packaging/AppIcon.icon) reduced to a menu bar
/// template. A centre pane between two side panes turned away in perspective, and the state shows
/// in how many are filled: outlines (idle), the centre filled (a device is connected), all three
/// filled (streaming), or outlines with a badge at the lower right (Oriel needs attention).
///
/// Drawn in code, so there is no asset to keep in sync, and marked as a template so the menu bar
/// tints it for light and dark bars and highlights it when the menu is open. `symbolFallback` (SF
/// Symbol macbook.and.ipad) is the stand-in if this drawing is ever dropped; the previews render
/// both side by side.
enum StatusGlyph {
    enum State: Equatable, CaseIterable { case idle, connected, streaming, attention }

    /// 18 pt tall: 14 pt of drawing and two points above and below, like the system's own items.
    static let size = NSSize(width: 23, height: 18)

    static let symbolFallback: NSImage? = {
        let image = NSImage(systemSymbolName: "macbook.and.ipad", accessibilityDescription: "Oriel")
        image?.isTemplate = true
        return image
    }()

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Oriel"
        return image
    }

    // MARK: Geometry, in points (flipped: y down)

    /// The panes' outline, drawn inside each shape.
    private static let line: CGFloat = 1.3
    private static let top: CGFloat = 2, bottom: CGFloat = 16

    /// The centre pane: 11 by 14, its corners rounded as the icon's.
    private static let centre = CGPath(roundedRect: CGRect(x: 6, y: top, width: 11, height: bottom - top),
                                       cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)

    /// A side pane: a trapezoid whose inner edge (beside the centre, 1.4 pt away) is nearly the
    /// centre's height and whose outer edge is three quarters of it, as the icon's are, its corners
    /// rounded by 0.7 pt (the polygon stroked with round joins, as the icon's SVG does).
    private static func side(left: Bool) -> CGPath {
        let r: CGFloat = 0.7, h = bottom - top
        let inner: CGFloat = 18.4 + r, outer: CGFloat = 22.4 - r
        let innerInset = h * 0.01 + r, outerInset = h * 0.125 + r
        let x = { (v: CGFloat) in left ? size.width - v : v }
        let core = CGMutablePath()
        core.addLines(between: [CGPoint(x: x(inner), y: top + innerInset), CGPoint(x: x(outer), y: top + outerInset),
                                CGPoint(x: x(outer), y: bottom - outerInset), CGPoint(x: x(inner), y: bottom - innerInset)])
        core.closeSubpath()
        return core.union(core.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }

    private static let sides = [side(left: true), side(left: false)]

    /// A pane filled, or its outline: the shape stroked at twice the line, clipped to itself.
    private static func pane(_ shape: CGPath, filled: Bool, in ctx: CGContext) {
        if filled { ctx.addPath(shape); ctx.fillPath(); return }
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.setLineWidth(2 * line)
        ctx.addPath(shape)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func draw(_ state: State, in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)

        pane(centre, filled: state == .connected || state == .streaming, in: ctx)
        for s in sides { pane(s, filled: state == .streaming, in: ctx) }

        // Attention: a dot at the lower right, cut out of whatever it overlaps.
        if state == .attention {
            let d = size.height * 0.42
            let dot = CGRect(x: size.width - d, y: size.height - d, width: d, height: d)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: dot)
        }
    }
}
