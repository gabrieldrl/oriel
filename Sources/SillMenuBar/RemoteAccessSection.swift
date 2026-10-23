import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › General's Remote Access (docs/settings-simple-plan.md): always on in Oriel.app, so no
/// switch. What it needs (a VPN such as Tailscale on both ends), the VPNs this Mac has, and the
/// port only while another app holds it. A device learns the Mac's VPN addresses whenever it
/// connects (kind 18, `SavedMacs.remembering`), so there is nothing to set up here. No internet
/// access: this fork has none (docs/reachable-plan.md). Values in, an action out, so the previews
/// can draw every state. Errors show inline, never in alerts.
struct RemoteAccessSection: View {
    let status: RemoteStatus
    /// The configured port (the app's is never 0).
    let port: Int
    var setPort: (Int) -> Void = { _ in }

    @State private var editingPort = false
    @State private var portText = ""

    var body: some View {
        let vpns = Self.addressRows(status.addresses).filter(\.vpn)
        Section {
            if let problem = status.identityProblem {
                Warning("Not available: Oriel couldn’t use its key in your keychain (\(withoutFullStop(problem))).")
            } else {
                ForEach(vpns) { row in
                    LabeledContent(row.label) { Text(row.primary).textSelection(.enabled) }
                }
                ForEach(status.vpnDown, id: \.self) { name in
                    LabeledContent(name) { Text("Not connected").foregroundStyle(.secondary) }
                }
                if vpns.isEmpty && status.vpnDown.isEmpty {
                    Text("No VPN on this Mac yet.").foregroundStyle(.secondary)
                }
                listenerProblem
            }
        } header: {
            Text("Remote Access")
        } footer: {
            Footnote("Turn on Tailscale, or another VPN, on this Mac and on your iPhone or iPad. Your devices learn this Mac’s VPN address the next time they connect at home, and use it when you’re away. Nothing else to set up.")
        }
    }

    /// The remote door's listener when it could not start: another app on its port (with a way to
    /// pick another), or any other failure.
    @ViewBuilder private var listenerProblem: some View {
        switch status.listener {
        case .portInUse(let p):
            Warning("Port \(p) is in use by another app. Oriel tries again every 30 seconds.")
            if editingPort {
                let problem = Self.portProblem(portText)
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .onSubmit { savePort() }
                            .onExitCommand { editingPort = false }
                        Button("Save") { savePort() }
                            .disabled(problem?.blocks ?? false)
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel") { editingPort = false }
                    }
                }
                if let problem {
                    if problem.blocks { Warning(problem.message) } else { Text(problem.message).foregroundStyle(.secondary) }
                }
            } else {
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        Text(String(port)).monospacedDigit()
                        Button("Change…") {
                            portText = String(port)
                            editingPort = true
                        }
                    }
                }
            }
        case .failed(let error):
            Warning("Remote access couldn’t start (\(error)). Oriel tries again every 30 seconds.")
        case .off, .listening:
            EmptyView()
        }
    }

    private func savePort() {
        if let problem = Self.portProblem(portText), problem.blocks { return }
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        editingPort = false
        if p != port { setPort(p) }
    }

    /// What is wrong with a port typed into the field: blocking (it cannot be saved), or only a
    /// warning. Nil when it is fine.
    static func portProblem(_ text: String) -> (message: String, blocks: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), t.count <= 5, let p = Int(t), (1024...65535).contains(p) else {
            return ("Choose a port from 1024 to 65535.", true)
        }
        if p == 5000 || p == 7000 { return ("Port \(p) belongs to AirPlay Receiver. Choose another.", true) }
        if p >= 49152 { return ("Ports from 49152 up can be taken by any app at any moment.", false) }
        return nil
    }

    // MARK: Helpers

    /// One row per way in: the service's name and the address devices dial first (a MagicDNS name
    /// before an IP). Never an internet address (an older list's would be skipped).
    struct AddressRow: Identifiable {
        var id: String { label }
        var label: String
        var primary: String
        var vpn: Bool
    }

    static func addressRows(_ addresses: [MacAddress]) -> [AddressRow] {
        var order: [String] = []
        var byVia: [String: [MacAddress]] = [:]
        for a in addresses where a.kind != MacAddress.internet {
            if byVia[a.via] == nil { order.append(a.via) }
            byVia[a.via, default: []].append(a)
        }
        return order.compactMap { via in
            guard let list = byVia[via] else { return nil }
            let isName: (MacAddress) -> Bool = { a in
                if case .success(let p) = AddressParser.parse(a.host) { return p.kind == .name }
                return false
            }
            let sorted = list.filter(isName) + list.filter { !isName($0) }
            guard let first = sorted.first else { return nil }
            return AddressRow(label: via, primary: first.host, vpn: list.contains { $0.kind == MacAddress.vpn })
        }
    }

    /// Battery on a laptop, Energy on a desktop: one System Settings extension on macOS 27
    /// (/System/Library/ExtensionKit/Extensions/PowerPreferences.appex).
    static func openEnergySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
