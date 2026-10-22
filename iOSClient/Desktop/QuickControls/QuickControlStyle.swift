import SwiftUI

/// The quick controls' shared look (QuickControls): their height and colours.
enum QuickControlStyle {
    static let height: CGFloat = 52
    /// A closed control's fill, and the open picker's track: no outline at rest, only the open
    /// picker's current choice is lit.
    static let fill = Color(white: 0.16)
    static let font = Font.system(size: 16, weight: .semibold)
    static let labelPadding: CGFloat = 18
    /// A control's icon, before its text.
    static let iconSize: CGFloat = 20
    static let iconFont = Font.system(size: 17, weight: .semibold)
    /// The room the icon takes before the closed choice (or the closed text): it draws from
    /// `iconInset`, and the choice's own padding makes the gap after it.
    static let iconSlot: CGFloat = 30
    static let iconInset: CGFloat = 16
}

/// A closed pill's face: its icon in the slot, then its text (FlipToggle's, the Apps pill's).
struct QuickPillFace: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: QuickControlStyle.iconSlot - QuickControlStyle.iconInset - QuickControlStyle.iconSize
                        + QuickControlStyle.labelPadding) {
            Image(systemName: icon)
                .font(QuickControlStyle.iconFont)
                .frame(width: QuickControlStyle.iconSize)
            Text(text)
        }
    }
}

extension View {
    /// A pill's room around its face: the row's height, the icon's inset before it, the text's after;
    /// its icon and text in `color` (black on a lit pill's white).
    func quickPillFrame(_ color: Color = .white) -> some View {
        foregroundStyle(color)
            .font(QuickControlStyle.font)
            .padding(.leading, QuickControlStyle.iconInset)
            .padding(.trailing, QuickControlStyle.labelPadding)
            .frame(minWidth: QuickControlStyle.height, minHeight: QuickControlStyle.height)
    }

    /// A round quick control (the sound's circle, the clipboard, Disconnect): the row's height across,
    /// on `fill`, and a tap anywhere in the circle.
    func quickCircle(_ fill: Color = QuickControlStyle.fill) -> some View {
        frame(width: QuickControlStyle.height, height: QuickControlStyle.height)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}
