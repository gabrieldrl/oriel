import SwiftUI

/// The block at the top of the status menu: whether a device is connected, and each connected
/// device's name. 300 pt wide, hosted in an NSMenuItem's view (StatusItemController).
struct StatusCard: View {
    let presentation: StatusPresentation

    /// "No Device Connected", "Device Connected", "2 Devices Connected".
    static func header(_ devices: [String]) -> String {
        switch devices.count {
        case 0: "No Device Connected"
        case 1: "Device Connected"
        default: "\(devices.count) Devices Connected"
        }
    }

    var body: some View {
        let devices = presentation.connectedDevices
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(devices.isEmpty ? Color.secondary.opacity(0.5) : Color.green)
                    .frame(width: 8, height: 8)
                    .frame(width: 16)   // the same column as the device symbols below
                Text(Self.header(devices))
                    .font(.headline)
            }
            ForEach(Array(devices.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 8) {
                    Image(systemName: name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "ipad")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}

/// The card in the live menu. It re-renders as the model's presentation changes, including while
/// the menu is open (the menu's tracking loop still runs main-actor hops).
struct LiveStatusCard: View {
    let model: AppModel

    var body: some View {
        StatusCard(presentation: model.presentation)
    }
}
