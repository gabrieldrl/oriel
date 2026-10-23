import SwiftUI
import StreamProtocol
import UserNotifications

/// Sill's own settings, from the home screen's gear: a modal of tabs, one so far.
///
/// - **Agents:** "Get notified when an agent on any connected Mac finishes", off by default
///   (MacLinks). On, each saved Mac has its own switch, and its line says whether it can notify:
///   connected or not (a Mac notifies only while connected: connect to it once, then close its
///   stream), and what keeps it from pushing (no push key on the Mac, iOS's notifications off).
struct SettingsScreen: View {
    @ObservedObject var client: StreamClient
    @ObservedObject private var links = MacLinks.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            NavigationStack {
                agents
                    .navigationTitle("Agents")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
            }
            .tabItem { Label("Agents", systemImage: "sparkles") }
        }
        .preferredColorScheme(.dark)
    }

    private var agents: some View {
        Form {
            Section {
                Toggle("Get notified when an agent on any connected Mac finishes",
                       isOn: Binding(get: { links.agentsNotify }, set: { links.setAgentsNotify($0) }))
            } footer: {
                Text("When Claude Code or Codex finishes a turn on a Mac you’re connected to, Sill on the Mac tells this \(StreamClient.deviceWord). Only each session’s title and project leave the Mac.")
            }
            if links.agentsNotify, links.permission == .denied {
                Section {
                    Button("Turn On Notifications in Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text("Notifications are off for Sill, so nothing can be shown.")
                }
            }
            if links.agentsNotify {
                Section {
                    ForEach(client.savedMacs) { mac in
                        Toggle(isOn: Binding(get: { links.notifies(mac.macID) }, set: { links.setNotifies(mac.macID, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.displayName(mac.macID))
                                Text(line(mac.macID))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("A Mac notifies while you’re connected to it. Closing its stream keeps it connected; Disconnect stops everything Sill does for this \(StreamClient.deviceWord) on that Mac.")
                }
            }
        }
    }

    /// Whether this Mac can notify now, and if not, why.
    private func line(_ macID: String) -> String {
        guard links.isConnected(macID) else { return "Not connected" }
        switch links.pushProblems[macID] {
        case LinkState.noKey?: return "Connected · The Mac has no push key yet"
        case LinkState.rejected?: return "Connected · The Mac can’t reach this \(StreamClient.deviceWord); open Sill to try again"
        default: break
        }
        switch links.states[macID] {
        case .up?: return "Connected"
        case .linking?: return "Connected · Reaching the Mac…"
        default: return "Connected · Reached when Sill opens"
        }
    }
}
