import SwiftUI

/// The black under the Mac's picture rising up over it, as if the screen's own black swelled up out
/// of the bottom edge: rounded at the top, flaring into the bottom edge at its base, a little
/// narrower than the picture so the picture's edges show either side of it. The Apps sheet
/// (AppsTray) and the key row (KeyRowSheet) are two of these.
///
/// It lies over the picture (DesktopScreen), its base on the picture's bottom edge. Its contents ride
/// its top edge up, the rest still under the picture's edge. With a `focusID`, open, it is the
/// screen's open control (QuickPillFocus): a touch anywhere else puts it away, and another control
/// opening closes it. Without one it stays up while the picture is used, until `open` goes false.
/// Where it rises over black instead of a picture (the iPhone held upright, DesktopScreen), its
/// outline is drawn as the picture's is (`\.risingSheetOutlined`).
struct RisingSheet<Content: View>: View {
    @Binding var open: Bool
    /// The sheet's width at its sides (its base flares out past them).
    let width: CGFloat
    /// Its height when up.
    let height: CGFloat
    var focusID: String? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.quickPillFocus) private var focus
    @Environment(\.risingSheetOutlined) private var outlined
    /// How far up the sheet is drawn, following `open` in the sheet's own spring.
    @State private var expanded = false

    var body: some View {
        let clip = UnevenRoundedRectangle(topLeadingRadius: RisingSheetStyle.topRadius, topTrailingRadius: RisingSheetStyle.topRadius,
                                          style: .continuous)
        content()
            .frame(width: width, height: height, alignment: .top)
            .opacity(expanded ? 1 : 0)
            // The sheet's top edge carries the contents up; what is still under it is cut off.
            .frame(width: width, height: expanded ? height : 0, alignment: .top)
            .clipShape(clip)
            .background {
                SheetShape(flare: RisingSheetStyle.flare, topRadius: RisingSheetStyle.topRadius).fill(Color.black)
                    .overlay {
                        if outlined {
                            SheetShape(flare: RisingSheetStyle.flare, topRadius: RisingSheetStyle.topRadius, closed: false)
                                .stroke(Color.white.opacity(0.09), lineWidth: 1)
                                .opacity(expanded ? 1 : 0)
                        }
                    }
                    .padding(.horizontal, -RisingSheetStyle.flare)
            }
            .contentShape(Rectangle())
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
            .modifier(FocusFrame(id: focusID, focus: focus, open: open))
            // Its base just past the picture's edge, over the picture's outline.
            .offset(y: 2)
            .onChange(of: open, initial: true) { _, isOpen in
                withAnimation(RisingSheetStyle.spring) { expanded = isOpen }
                guard let focusID else { return }
                if isOpen {
                    focus?.opened(focusID) { open = false }
                } else {
                    focus?.closed(focusID)
                }
            }
    }
}

/// A rising sheet's measures, shared by every one.
enum RisingSheetStyle {
    /// How much of the picture shows either side of a sheet.
    static let inset: CGFloat = 32
    static let topRadius: CGFloat = 32
    /// The base's flare into the bottom edge, at each side.
    static let flare: CGFloat = 20
    static let spring = Animation.spring(duration: 0.45, bounce: 0.14)

    /// A sheet's width over a picture `width` wide.
    static func width(over width: CGFloat) -> CGFloat { max(width - 2 * inset, 0) }
}

private struct RisingSheetOutlinedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Rising sheets here rise over black, not over the picture: their outline is drawn.
    var risingSheetOutlined: Bool {
        get { self[RisingSheetOutlinedKey.self] }
        set { self[RisingSheetOutlinedKey.self] = newValue }
    }
}

/// While a focused sheet is open, its frame to QuickPillFocus (the catcher's hole).
private struct FocusFrame: ViewModifier {
    let id: String?
    let focus: QuickPillFocus?
    let open: Bool

    func body(content: Content) -> some View {
        if let id {
            content.reportsPillFrame(id, to: focus, while: open)
        } else {
            content
        }
    }
}

/// The sheet's outline in its rect, whose sides lie `flare` in from the rect's: straight up from a
/// base that curves out into the rect's bottom edge, as liquid meets a surface, to rounded top corners.
/// A low sheet, early in its rise, flares and rounds less. Not `closed`, the base is left open (an
/// outline to stroke).
private struct SheetShape: Shape {
    let flare: CGFloat
    let topRadius: CGFloat
    var closed = true

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + flare, right = rect.maxX - flare
        let f = min(flare, rect.height / 2)
        let r = max(min(topRadius, rect.height - f, (right - left) / 2), 0)
        var path = Path()
        path.move(to: CGPoint(x: left - f, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - f), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left + r, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: right - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.minY + r), radius: r)
        path.addLine(to: CGPoint(x: right, y: rect.maxY - f))
        path.addQuadCurve(to: CGPoint(x: right + f, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        if closed { path.closeSubpath() }
        return path
    }
}
