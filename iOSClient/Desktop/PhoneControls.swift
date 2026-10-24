import SwiftUI
import StreamProtocol

/// The iPhone's bar over the picture, upright (DesktopScreen's phone layout): the Mac's name, then
/// the info button and Disconnect at the trailing end.
struct PhoneTopBar: View {
    @ObservedObject var client: StreamClient
    let infoOpen: Bool
    let onInfo: () -> Void
    let onDisconnect: () -> Void

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            Text(client.macName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            InfoButton(open: infoOpen, onTap: onInfo)
            PhoneDisconnect(client: client, onDisconnect: onDisconnect)
        }
        .frame(height: Self.height)
    }
}

/// Disconnect on the iPhone, the info button's size: a close mark in red on a red tint, as the iPad's.
struct PhoneDisconnect: View {
    @ObservedObject var client: StreamClient
    let onDisconnect: () -> Void

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.red)
            .frame(width: InfoButton.size, height: InfoButton.size)
            .background(Circle().fill(Color.red.opacity(0.18)))
            .contentShape(Circle())
            .onTapGesture { onDisconnect() }
            .accessibilityElement()
            .accessibilityLabel(client.macName.isEmpty ? "Disconnect" : "Disconnect from \(client.macName)")
            .accessibilityAddTraits(.isButton)
    }
}

/// The iPhone's quick controls, one round icon each: a row at the bottom with the phone upright, a
/// column at the left held sideways, the info button and Disconnect at its top (no top bar then).
/// Settings (the stream's settings, Touch or Trackpad, the Mac's sound, clipboard and screen off:
/// PhoneSettingsSheet), Apps, Displays (for a Mac that makes them), Keys (the key row:
/// PhoneKeysSheet), and the keyboard. Each but the keyboard opens a black sheet (RisingSheet) and is
/// lit while it is up; the keyboard is lit while it shows.
struct PhoneControlBar: View {
    @ObservedObject var client: StreamClient
    let vertical: Bool
    @Binding var settingsOpen: Bool
    @Binding var appsOpen: Bool
    @Binding var displaysOpen: Bool
    @Binding var keysOpen: Bool
    let keyboardShown: Bool
    let onKeyboard: () -> Void
    /// The column's info button and Disconnect.
    let infoOpen: Bool
    let onInfo: () -> Void
    let onDisconnect: () -> Void

    static let settingsIcon = "slider.horizontal.3"
    /// Between two icons in the column.
    private static let columnSpacing: CGFloat = 10

    var body: some View {
        if vertical {
            VStack(spacing: Self.columnSpacing) {
                InfoButton(open: infoOpen, onTap: onInfo)
                PhoneDisconnect(client: client, onDisconnect: onDisconnect)
                Spacer(minLength: 6)
                icons
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 0) { icons }
        }
    }

    @ViewBuilder private var icons: some View {
        Group {
            icon(Self.settingsIcon, lit: settingsOpen, label: "Settings") { settingsOpen.toggle() }
            icon(AppsTray.icon, lit: appsOpen, label: "Apps") { appsOpen.toggle() }
            if client.hostMakesDisplays {
                icon(DisplaysTray.icon, lit: displaysOpen, label: "Displays") { displaysOpen.toggle() }
            }
            icon(KeyRowSheet.icon, lit: keysOpen, label: keysOpen ? "Hide the key row" : "Show the key row") { keysOpen.toggle() }
            icon("keyboard", lit: keyboardShown, label: keyboardShown ? "Hide the keyboard" : "Show the keyboard",
                 action: onKeyboard)
        }
    }

    /// One icon; in the row, each takes an equal share of its width.
    private func icon(_ symbol: String, lit: Bool, label: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(QuickControlStyle.iconFont)
            .foregroundStyle(lit ? Color.black : Color.white)
            .quickCircle(lit ? Color.white : QuickControlStyle.fill)
            .onTapGesture { action() }
            .animation(.easeOut(duration: 0.2), value: lit)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
            .frame(maxWidth: vertical ? nil : .infinity)
    }
}
