import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One Settings tab: a grouped Form, 520 pt wide. The controls bind straight to
/// `settings.config`, whose didSet is the one path to the host (see HostSettings).
struct SettingsPane: View {
    let tab: SettingsTab
    let model: AppModel
    /// The previews (DebugHooks): General's update section in this state instead of the live one,
    /// so a render does not depend on what an earlier run stored.
    var previewUpdates: UpdatePolicy.Pane?
    /// …and its clipboard section with macOS's answer as given, never read from this Mac.
    var previewClipboardAccess: ClipboardPolicy.MacAccess?

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane(model: model, settings: model.settings, previewUpdates: previewUpdates,
                                       previewClipboardAccess: previewClipboardAccess)
            case .devices: LiveDevicesPane(model: model)
            case .permissions: PermissionsPane(model: model)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        // Permissions and the login item change behind Sill's back, in System Settings. Re-read
        // them once a second, only while this tab is on screen, and when Sill becomes active; an
        // idle Sill with Settings closed wakes for nothing. The Devices pane and General's Remote
        // Access follow the host's status, which is pushed, so they poll nothing.
        .task(id: model.visibleSettingsTab == tab) {
            guard model.visibleSettingsTab == tab, tab != .devices else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.loginItem.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.loginItem.refresh()
        }
    }
}

/// Footer text the way System Settings sets it: small, secondary, from the leading edge.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An orange problem line with its sign.
struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A system error message inside a sentence of ours: without its own full stop.
func withoutFullStop(_ text: String) -> String {
    text.hasSuffix(".") ? String(text.dropLast()) : text
}

// MARK: General

/// Launch at login, the Mac's name, the clipboard, the update check, Remote Access (always on: what
/// it needs, and the VPNs it sees), sleep, Contact and Quit. Nothing about how a stream looks: each device
/// sets that for itself.
private struct GeneralPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    var previewUpdates: UpdatePolicy.Pane?
    var previewClipboardAccess: ClipboardPolicy.MacAccess?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.set($0) }))
                    .disabled(!model.loginItem.available)
                if model.loginItem.needsApproval {
                    LabeledContent("Waiting for your approval") {
                        Button("Approve in System Settings…") { model.loginItem.openSystemSettings() }
                    }
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                LabeledContent("Mac name") {
                    HStack(spacing: 8) {
                        Text(networkName)
                        Button("Change…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            // The clipboard both ways (HostClipboard): at once, no restart. Each device has its own
            // switch too. macOS's answer is read with the permissions (once a second while this pane
            // shows, and when Sill becomes active), never in a preview.
            ClipboardSection(shareClipboard: $settings.config.shareClipboard,
                             access: previewClipboardAccess ?? model.permissions.clipboardAccess,
                             allow: { model.permissions.allowClipboard() })
            if let preview = previewUpdates {
                UpdatesSection(pane: preview, automatic: .constant(true))
            } else {
                UpdatesSection(pane: model.updates.pane, automatic: $settings.updateCheck,
                               actions: UpdatesSection.Actions(checkNow: { model.updates.checkNow() },
                                                               openRelease: { NSWorkspace.shared.open($0) }))
            }
            RemoteAccessSection(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                                port: settings.config.remotePort,
                                setPort: { settings.config.remotePort = $0 })
            Section {
                LabeledContent {
                    Button("Open Energy Settings…") { RemoteAccessSection.openEnergySettings() }
                } label: {
                    Text("Sleep")
                    Text("Your devices can’t reach this Mac while it’s asleep.")
                }
            }
            Section {
                // A way out when the status item is hidden (a crowded menu bar, the notch), and a way
                // to write to the developer (Mail, or whatever app handles mailto).
                HStack {
                    Button("Contact") { if let url = Self.feedbackMail { NSWorkspace.shared.open(url) } }
                    Button("Quit Oriel") { NSApp.terminate(nil) }
                }
            } footer: {
                Footnote("Oriel \(AppModel.version) (\(AppModel.build))")
            }
        }
    }

    /// A new message to the developer, its subject naming this version.
    private static var feedbackMail: URL? {
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = "g@gdrl.dev"
        mail.queryItems = [URLQueryItem(name: "subject", value: "Oriel \(AppModel.version) (\(AppModel.build)) feedback")]
        return mail.url
    }

    private var networkName: String {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        switch snapshot.network {
        case .advertising(let name): return name
        case .notAdvertised: return "Not advertised (test pattern)"
        case .failed: return "Not visible"
        case .waiting: return "Waiting for the network"
        case .starting, .registering: return "Registering…"
        }
    }
}

// MARK: Clipboard

/// Share clipboard with devices (HostClipboard, docs/clipboard-plan.md): the switch and its footnote,
/// and while the switch is on and macOS does not allow every read Sill makes on its own
/// (ClipboardPolicy.MacAccess), why what is copied here stays on this Mac and the way to allow it.
/// Drawn alone in the previews in each of macOS's answers (DebugHooks).
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    var body: some View {
        Section {
            Toggle("Share clipboard with devices", isOn: $shareClipboard)
            if shareClipboard, let warning = ClipboardPolicy.Copy.macAccessWarning(access) {
                VStack(alignment: .leading, spacing: 6) {
                    Warning(warning)
                    if let hint = ClipboardPolicy.Copy.macAccessHint(access) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(ClipboardPolicy.Copy.macAccessButton, action: allow)
                }
            }
        } footer: {
            Footnote(ClipboardPolicy.Copy.macFootnote)
        }
    }
}

// MARK: Updates

/// Settings › General's update check: the automatic switch, the line (what the last check found, or
/// why Sill cannot check), Open Release Page… while a newer release is offered, and Check Now. Plain
/// values in, so the previews draw every state. Errors show here and in the log, never in an alert.
struct UpdatesSection: View {
    struct Actions {
        var checkNow: () -> Void = {}
        var openRelease: (URL) -> Void = { _ in }
    }

    let pane: UpdatePolicy.Pane
    @Binding var automatic: Bool
    var actions = Actions()

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $automatic)
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = pane.releasePage {
                        Button("Open Release Page…") { actions.openRelease(url) }
                    }
                    Button("Check Now") { actions.checkNow() }
                        .disabled(!pane.canCheck)
                }
            } label: {
                Text(pane.line)
                    .foregroundStyle(pane.failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VoiceOver hears Check Now's result, which arrives after the click.
            .onChange(of: pane.resultID) { _, _ in
                AccessibilityNotification.Announcement(pane.line).post()
            }
        } footer: {
            Footnote(UpdatePolicy.footnote)
        }
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let network = model.coordinator?.status.snapshot.network
        Form {
            Section {
                PermissionRow(title: "Screen Recording", allowed: permissions.screenRecording,
                              explanation: "Shows your windows on your devices. Nothing is saved.",
                              button: model.settings.askedScreenRecording ? "Open System Settings…" : "Allow…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(title: "Accessibility", allowed: permissions.accessibility,
                              explanation: "Lets your devices click, scroll and type here.",
                              button: model.settings.askedAccessibility ? "Open System Settings…" : "Allow…") {
                    permissions.requestAccessibility()
                }
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    LabeledContent("Screen Recording works once Oriel reopens.") {
                        Button(permissions.canRelaunch ? "Relaunch Oriel" : "Quit Oriel") { permissions.relaunch() }
                    }
                }
            }
            if Self.networkNeedsHelp(network) {
                Section {
                    LabeledContent {
                        Button("Open Local Network…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    } label: {
                        Text("Local Network")
                        Text("If your devices can’t find this Mac, allow Oriel here.")
                    }
                }
            }
            if permissions.allGranted {
                Section {
                    Label("You’re all set.", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private static func networkNeedsHelp(_ network: HostStatusSnapshot.Network?) -> Bool {
        switch network {
        case .waiting, .failed: return true
        default: return false
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let explanation: String
    let button: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(button, action: action)
                }
            }
        } label: {
            Text(title)
            Text(explanation)
        }
    }
}
