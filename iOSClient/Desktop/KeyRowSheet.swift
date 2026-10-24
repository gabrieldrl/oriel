import SwiftUI
import UIKit
import StreamProtocol

/// The key row, a RisingSheet over the picture: the keys a Mac needs that the on-screen keyboard
/// does not offer (KeyCaps).
///
/// It stays up while the picture is used, until the typing pill's key row column puts it away
/// (QuickControls), or the Apps sheet takes its place (DesktopScreen).
struct KeyRowSheet: View {
    @ObservedObject var client: StreamClient
    @Binding var open: Bool
    @Binding var latched: KeyModifiers
    /// The Mac's picture on screen, which the sheet rises over.
    let picture: CGSize

    private static let vertical: CGFloat = 14
    /// Clear of the sheet's rounded top corners.
    private static let horizontal: CGFloat = 24

    static let icon = "command"

    var body: some View {
        RisingSheet(open: $open, width: RisingSheetStyle.width(over: picture.width),
                    height: KeyCaps.capHeight + 2 * Self.vertical) {
            KeyCaps(client: client, latched: $latched)
                .padding(.horizontal, Self.horizontal)
                .padding(.vertical, Self.vertical)
        }
        // Put away, it holds nothing: a latch nobody can see would surprise the next tap.
        .onChange(of: open) { _, isOpen in if !isOpen { latched = [] } }
    }
}

/// The keys a Mac needs that the on-screen keyboard does not offer: Escape, tab, the four modifiers,
/// the four arrows and, while the whole Desktop streams, Spotlight (its panel is a Mac window of its
/// own, so over a window it would do something unseen). A modifier stays lit until the next key,
/// character or click uses it, or until it is tapped again (`latched`, which the picture's input
/// spends too). In one row (KeyRowSheet), or two, the arrows and Spotlight on the second (the
/// iPhone's controls sheet, PhoneSheets).
struct KeyCaps: View {
    @ObservedObject var client: StreamClient
    @Binding var latched: KeyModifiers
    var rows = 1

    private enum Key {
        /// A key that types itself: the cap's text, its HID usage, its accessibility label.
        case press(String, UInt16, String)
        /// An arrow: SF Symbol, HID usage, label.
        case arrow(String, UInt16, String)
        /// A latching modifier: cap text, the bit it holds, its name.
        case modifier(String, KeyModifiers, String)
        /// Spotlight on the Mac: always exactly ⌘Space, whatever is latched.
        case spotlight
    }

    private static let keys: [Key] = [
        .press("esc", HIDKey.escape, "Escape"),
        .press("tab", HIDKey.tab, "Tab"),
        .modifier("ctrl", .control, "Control"),
        .modifier("opt", .option, "Option"),
        .modifier("cmd", .command, "Command"),
        .modifier("shift", .shift, "Shift"),
        .arrow("chevron.left", HIDKey.leftArrow, "Left arrow"),
        .arrow("chevron.down", HIDKey.downArrow, "Down arrow"),
        .arrow("chevron.up", HIDKey.upArrow, "Up arrow"),
        .arrow("chevron.right", HIDKey.rightArrow, "Right arrow"),
        .spotlight,
    ]
    /// Where the second of two rows starts: the arrows.
    private static let secondRow = 6

    static let capHeight: CGFloat = 44
    static let capSpacing: CGFloat = 8

    /// Their height in `rows` rows.
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * capHeight + CGFloat(max(rows - 1, 0)) * capSpacing }

    private var shown: [Key] {
        client.active == .desktop ? Self.keys : Self.keys.filter { if case .spotlight = $0 { return false } else { return true } }
    }

    var body: some View {
        let keys = shown
        let lines = rows > 1 ? [Array(keys.prefix(Self.secondRow)), Array(keys.dropFirst(Self.secondRow))] : [keys]
        VStack(spacing: Self.capSpacing) {
            ForEach(lines.indices, id: \.self) { line in
                HStack(spacing: Self.capSpacing) {
                    ForEach(lines[line].indices, id: \.self) { index in cap(lines[line][index]) }
                }
                .frame(height: Self.capHeight)
            }
        }
    }

    @ViewBuilder private func cap(_ key: Key) -> some View {
        switch key {
        case .press(let title, _, let label):
            capFace(key, on: false, label: label) { Text(title) }
        case .arrow(let symbol, _, let label):
            capFace(key, on: false, label: label) { Image(systemName: symbol) }
        case .modifier(let title, let flag, let label):
            let on = latched.contains(flag)
            capFace(key, on: on, label: on ? "\(label), held. Tap to release." : "\(label), hold for the next key") {
                Text(title)
            }
        case .spotlight:
            capFace(key, on: false, label: "Open Spotlight on the Mac") { Image(systemName: Spotlight.symbol) }
        }
    }

    private func capFace<Face: View>(_ key: Key, on: Bool, label: String, @ViewBuilder face: () -> Face) -> some View {
        Button { tap(key) } label: { face() }
            .buttonStyle(CapStyle(on: on))
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What a tap on each cap does. Escape, tab and the arrows go down and up carrying whatever is
    /// latched, and spend it: ⌥← is a tap on opt, then one on the left arrow.
    private func tap(_ key: Key) {
        // A key's click, as the iPhone's own keyboard gives one (an iPad has no Taptic Engine: nothing).
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch key {
        case .press(_, let usage, _), .arrow(_, let usage, _):
            KeyChord.press(usage, with: latched).forEach { client.sendInput($0) }
            latched = []
        case .modifier(_, let flag, _):
            latched.formSymmetricDifference(flag)
        case .spotlight:
            // Latched modifiers do not join ⌘Space, but the tap still spends them.
            Spotlight.press { client.sendInput($0) }
            latched = []
        }
    }
}

/// A cap's look: lit white while its modifier is held, and lighter under the finger, as a keyboard's
/// key is, fading back once it lets go so even a quick tap shows.
private struct CapStyle: ButtonStyle {
    let on: Bool

    /// Under the finger: a lighter grey, or a held modifier's white a little dimmed.
    private static let pressedFill = Color(white: 0.36)
    private static let pressedLit = Color(white: 0.78)

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let pressed = configuration.isPressed
        let fill = on ? (pressed ? Self.pressedLit : Color.white) : (pressed ? Self.pressedFill : QuickControlStyle.fill)
        configuration.label
            .font(QuickControlStyle.font)
            .foregroundStyle(on ? Color.black : Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(fill))
            .contentShape(shape)
            // Down at once, back over a moment.
            .animation(pressed ? nil : .easeOut(duration: 0.25), value: pressed)
            .animation(.easeOut(duration: 0.15), value: on)
    }
}
