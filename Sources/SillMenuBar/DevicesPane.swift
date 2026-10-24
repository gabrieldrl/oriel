import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Devices, live: the paired devices from the host's status (pushed, so nothing polls),
/// with the model's actions.
struct LiveDevicesPane: View {
    let model: AppModel

    var body: some View {
        DevicesPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                    actions: DevicesPane.Actions(remove: { model.removeDevice($0) },
                                                 rename: { model.renameDevice($0, to: $1) },
                                                 pair: { model.pairDevice() }))
    }
}

/// The Devices pane (docs/settings-simple-plan.md): the devices paired with this Mac (one trust list,
/// at home and away), each with Remove, and Pair New Device… (the pairing window and its code).
/// Pairing is always required in Oriel.app, so no switch; it also starts on the device (over the USB
/// cable by itself, or a code this Mac shows when the device asks). Values in, actions out, so the
/// previews can draw every state. Errors show inline, never in alerts.
struct DevicesPane: View {
    struct Actions {
        /// Nil when the device was removed; otherwise why it is still paired.
        var remove: (String) -> String? = { _ in nil }
        var rename: (String, String) -> Void = { _, _ in }
        /// Pair New Device…: a pairing window, or the open one brought forward.
        var pair: () -> Void = {}
    }

    let status: RemoteStatus
    let actions: Actions

    /// A Remove the keychain did not keep: the device's name and why.
    @State private var removeProblem: (name: String, reason: String)?

    /// Why devices can't connect at all: the identity (the key, the trust list) could not be used,
    /// so the home door has no listener. Nil when it works.
    private var unavailable: String? {
        if let problem = status.identityProblem { return problem }
        if case .unavailable(let why) = status.homeDoor { return why }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if let problem = unavailable {
                    // The trust list lives with the key: unread, not empty.
                    Warning("Devices can’t connect: Oriel couldn’t use its key in your keychain (\(withoutFullStop(problem))). Quit Oriel and open it again.")
                } else if status.paired.isEmpty {
                    Text("None yet. Open Oriel on your iPhone or iPad to pair.").foregroundStyle(.secondary)
                }
                if let removeProblem {
                    Warning("\(removeProblem.name) is still paired: Oriel couldn’t update the keychain (\(withoutFullStop(removeProblem.reason))). Try again.")
                }
                ForEach(status.paired) { device in
                    PairedDeviceRow(device: device,
                                    remove: {
                                        // Gone from the list only once the keychain kept it:
                                        // otherwise the device would be trusted again at the next launch.
                                        if let reason = actions.remove(device.id) {
                                            removeProblem = (device.name, reason)
                                        } else {
                                            removeProblem = nil
                                        }
                                    },
                                    rename: { actions.rename(device.id, $0) })
                }
                HStack {
                    Spacer()
                    Button("Pair New Device…", action: actions.pair)
                        .disabled(unavailable != nil)
                }
            } header: {
                Text("Paired Devices")
            } footer: {
                Footnote("Remove a device to unpair it. To use it again, pair it again.")
            }
        }
    }
}

/// One paired device: its name (double-click to rename: Return saves, Esc cancels) and Remove, with
/// no confirmation since it only takes access away.
struct PairedDeviceRow: View {
    let device: PairedDeviceSummary
    let remove: () -> Void
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            Button("Remove", action: remove)
        } label: {
            if editing {
                TextField("Name", text: $text)
                    .focused($focused)
                    .onSubmit {
                        rename(text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(device.name)
                    .onTapGesture(count: 2) { startEditing() }
                    .accessibilityAction(named: "Rename") { startEditing() }
            }
        }
    }

    private func startEditing() {
        text = device.name
        editing = true
        focused = true
    }
}
