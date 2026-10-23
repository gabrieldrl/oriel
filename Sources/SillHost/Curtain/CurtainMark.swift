import SwiftUI

/// What the curtain shows on each of the Mac's own displays (MacCurtain): black, with Oriel's bay
/// window (Packaging/AppIcon.icon) large in the middle, in Liquid Glass. No text. Sill's own windows
/// are in no capture, so the devices never see it.
struct CurtainMark: View {
    /// The icon's fill (Packaging/AppIcon.icon's icon.json).
    static let blue = Color(red: 0.15, green: 0.40, blue: 0.95)

    var body: some View {
        GeometryReader { g in
            // About a third of the display's width, and never more than half its height.
            let width = min(g.size.width * 0.34, g.size.height * 0.5 * OrielMarkShape.aspect)
            ZStack {
                Color.black
                // A dim glow of the icon's blue behind it: glass over plain black has nothing to bend
                // and reads as a flat grey.
                Ellipse()
                    .fill(RadialGradient(colors: [Self.blue.opacity(0.55), Self.blue.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: width * 0.6))
                    .frame(width: width * 1.3, height: width * 0.9)
                    .blur(radius: width * 0.08)
                Color.clear
                    .glassEffect(.regular, in: OrielMarkShape())
                    .frame(width: width, height: width / OrielMarkShape.aspect)
            }
        }
        .ignoresSafeArea()
    }
}

/// The icon's three panes as one shape: the centre's rounded rectangle and the two side panes, each a
/// trapezoid stroked with round joins as the icon's SVG draws it (Centre.svg, Sides.svg), fitted to
/// the rect it is given.
struct OrielMarkShape: Shape {
    /// The drawing in the icon's 1024-point canvas: from the left pane's outer edge to the right's
    /// (the polygons and half their 56-point stroke), the centre's top to its bottom.
    static let bounds = CGRect(x: 198, y: 318, width: 628, height: 388)
    static var aspect: CGFloat { bounds.width / bounds.height }

    func path(in rect: CGRect) -> Path {
        var mark = Path(roundedRect: CGRect(x: 352, y: 318, width: 320, height: 388), cornerRadius: 44)
        for (outer, inner) in [(226.0, 300.0), (798.0, 724.0)] {
            var side = Path()
            side.addLines([CGPoint(x: outer, y: 394), CGPoint(x: inner, y: 350),
                           CGPoint(x: inner, y: 674), CGPoint(x: outer, y: 630)])
            side.closeSubpath()
            mark.addPath(side.union(side.strokedPath(StrokeStyle(lineWidth: 56, lineJoin: .round))))
        }
        let b = Self.bounds
        let scale = min(rect.width / b.width, rect.height / b.height)
        let x = rect.midX - b.midX * scale, y = rect.midY - b.midY * scale
        return mark.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }
}
