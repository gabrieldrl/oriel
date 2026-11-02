import SwiftUI
import StreamProtocol

/// One Mac's settings, the Mac's own rather than this device's: from its home card's menus and the
/// info panel's Mac Settings. Today Extended Use alone (StreamClient+KeepAwake,
/// docs/extended-use-plan.md): Off, Always, or When Plugged In on a Mac with a battery, Always's one
/// line, and what the Mac last said: kept awake now, waiting for its Login Items approval, on battery,
/// or a change that goes at the next connection. Connected to an Oriel that lacks it: "Update Oriel".
struct MacSettingsScreen: View {
    @ObservedObject var client: StreamClient
    let macID: String
    let close: () -> Void

    private var mac: String { client.displayName(macID) }
    private var live: Bool { client.connected(to: macID) }
    /// Connected to a Mac whose Oriel has no Extended Use.
    private var older: Bool { live && client.sessionListed && !client.hostHasKeepAwake }
    private var state: KeepAwake? {
        _ = client.keepAwakeRevision
        return client.keepAwakeState(macID)
    }
    private var mode: KeepAwakeMode { state.flatMap { KeepAwakeMode(rawValue: $0.mode) } ?? .off }
    /// Unknown until the Mac has said: When Plugged In offered.
    private var battery: Bool { state?.battery ?? true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Extended Use", selection: Binding(get: { mode }, set: { client.setKeepAwake($0, macID: macID) })) {
                        ForEach(battery ? KeepAwakeMode.allCases : [.off, .always], id: \.self) { mode in
                            Text(Self.word(mode)).tag(mode)
                        }
                    }
                    .disabled(older)
                    if mode == .always, battery, !older {
                        Text("Increases heat and battery use.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let line = status {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Keeps \(mac) awake, even with its lid closed, so you can always connect.")
                }
            }
            .navigationTitle(mac)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// What the Mac last said, or what waits for it.
    private var status: String? {
        if older { return "Update Oriel on \(mac) to keep it awake from here." }
        if !live, Self.waiting(macID) { return "Changes when you next connect to \(mac)." }
        guard let state, mode != .off else { return nil }
        switch state.problem {
        case KeepAwake.approval?: return "Allow Oriel in Login Items on \(mac): it asks in System Settings."
        case KeepAwake.unavailable?: return "This copy of Oriel on \(mac) can’t keep it awake."
        default: break
        }
        if mode == .plugged, state.onPower == false { return "\(mac) is on battery, so it sleeps as it would." }
        if live, state.awake == true { return "Keeping \(mac) awake." }
        return nil
    }

    private static func waiting(_ macID: String) -> Bool { StreamClient.keepAwakePending(macID) != nil }

    static func word(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: return "Off"
        case .always: return "Always"
        case .plugged: return "When Plugged In"
        }
    }
}

/// A Mac's id as a sheet's item.
struct MacSettingsID: Identifiable {
    let id: String
}
