import SwiftUI

/// A ripple across the Mac's picture, as a stone dropped in water: rings of Liquid Glass running out
/// from its centre, refracting the picture under them, with black spreading behind the first ring.
/// One number sets every frame: 0 is no ripple, 1 the rings past the picture's corners and the
/// picture all black. Disconnect runs it from 0 to 1 before the connect screen comes back; a new
/// session runs it from 1 to 0, so the rings come in from the edges and the picture fills in behind
/// them towards the centre (DesktopScreen).
///
/// Drawn over the picture, never through it: the picture is a UIKit video layer, which a SwiftUI
/// shader cannot sample, but glass refracts whatever lies under it. Before iOS 26, which has no
/// Liquid Glass, the rings are a pale tint.
struct DisplayRipple: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// The rings: how far each trails the first, and how wide it is.
    private static let rings: [(lag: CGFloat, width: CGFloat)] = [(0, 30), (70, 20), (130, 12)]

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let size = geo.size
                // The first ring's radius: from the centre to past the corners, its width included.
                let reach = hypot(size.width, size.height) / 2 + Self.rings[0].width
                let front = min(max(progress, 0), 1) * reach
                ZStack {
                    if progress > 0.001 {
                        Circle()
                            .fill(Color.black)
                            .frame(width: max(front - 12, 0) * 2, height: max(front - 12, 0) * 2)
                        ForEach(Self.rings.indices, id: \.self) { i in
                            let ring = Self.rings[i]
                            let radius = front - ring.lag
                            if radius > 0 {
                                RippleRing(radius: radius, width: ring.width)
                            }
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// One ring of the ripple, centred in its frame.
private struct RippleRing: View {
    let radius: CGFloat
    let width: CGFloat

    var body: some View {
        let ring = Ring(radius: radius, width: width)
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.clear, in: ring)
        } else {
            ring.fill(Color.white.opacity(0.18))
        }
    }
}

/// A band `width` wide around a circle of `radius`, centred in the rect.
private struct Ring: Shape {
    let radius: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        let circle = CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)
        return Path(ellipseIn: circle).strokedPath(StrokeStyle(lineWidth: width))
    }
}

extension View {
    /// The picture's ripple at `progress` (DisplayRipple).
    func displayRipple(_ progress: CGFloat) -> some View {
        modifier(DisplayRipple(progress: progress))
    }
}
