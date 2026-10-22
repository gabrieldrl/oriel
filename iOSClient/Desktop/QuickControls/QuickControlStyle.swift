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

extension View {
    /// A round quick control (the sound's circle, the clipboard, Disconnect): the row's height across,
    /// on `fill`, and a tap anywhere in the circle.
    func quickCircle(_ fill: Color = QuickControlStyle.fill) -> some View {
        frame(width: QuickControlStyle.height, height: QuickControlStyle.height)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}
