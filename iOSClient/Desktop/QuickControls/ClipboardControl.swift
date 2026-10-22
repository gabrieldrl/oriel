import SwiftUI
import StreamProtocol

/// The Mac's clipboard: a plain clipboard while there is nothing new from the Mac, a full one, lit,
/// once the Mac has copied text, and a tap puts that text on this device's clipboard (a tick for a
/// moment). Dimmed while the Mac shares no clipboard or this device's Share Clipboard is off.
struct ClipboardControl: View {
    @ObservedObject var client: StreamClient
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    private var available: Bool { ClipboardPolicy.hostTakes(client.hostClipboard) && StreamClient.clipboardOn }
    private var waiting: Bool { available && client.macClipboardText != nil }

    private var symbol: String {
        if copied { return "checkmark" }
        return waiting ? "list.clipboard.fill" : "clipboard"
    }

    var body: some View {
        Image(systemName: symbol)
            .font(QuickControlStyle.iconFont)
            .foregroundStyle(waiting ? Color.black : Color.white)
            .contentTransition(.symbolEffect(.replace))
            .quickCircle(waiting ? Color.white : QuickControlStyle.fill)
            .opacity(available ? 1 : 0.4)
            .animation(.spring(duration: 0.3, bounce: 0.1), value: waiting)
            .animation(.spring(duration: 0.3, bounce: 0.1), value: copied)
            .onTapGesture { take() }
            .accessibilityElement()
            .accessibilityLabel("Mac Clipboard")
            .accessibilityValue(waiting ? "New text from the Mac" : "Nothing new")
            .accessibilityHint(waiting ? "Copies it to this device" : "")
            .accessibilityAddTraits(.isButton)
            #if DEBUG
            // `-SillMacClipboard <text>`: the Mac has just copied that text.
            .onAppear {
                if let text = UserDefaults.standard.string(forKey: "SillMacClipboard") { client.macClipboardText = text }
            }
            #endif
    }

    private func take() {
        guard waiting else { return }
        client.takeMacClipboard()
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { copied = false }
        }
    }
}
