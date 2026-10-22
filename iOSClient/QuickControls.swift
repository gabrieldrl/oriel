import SwiftUI
import StreamProtocol

/// The row of quick controls under the Mac's picture on the new main screen (DesktopScreen),
/// across the picture's width. Each is its own view below, built from the shared pieces (FlipToggle,
/// MorphingPicker, QuickControlStyle): Resolution, Frame Rate, then Quality, which moves along whatever
/// comes after it when it opens; the clipboard at the trailing edge.
///
/// The three settings are the Mac's own, as its menu sets them: one stream serves every device, so
/// they apply to all of them, and Sill.app keeps them for later sessions. A device away from home
/// sets the Mac's away quality and resolution instead (DeviceSettings.applyingAway).
struct QuickControls: View {
    @ObservedObject var client: StreamClient
    /// Touch or trackpad input (DesktopScreen's).
    @Binding var trackpadInput: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let shown = client.settings.displayed {
                ResolutionControl(client: client, captureScale: shown.captureScale)
                FrameRateControl(client: client, maxFPS: shown.maxFPS)
                QualityControl(client: client, bitrate: shown.bitrate)
            }
            Spacer(minLength: 0)
            FlipToggle(options: [false, true], selection: trackpadInput,
                       label: { $0 ? "Trackpad" : "Touch" },
                       icon: { $0 ? "cursorarrow" : "hand.tap" }, accessibilityLabel: "Input") { trackpadInput = $0 }
            ClipboardControl(client: client)
            DisconnectControl(client: client)
        }
        .frame(height: QuickControlStyle.height)
    }
}

/// Disconnect, at once on a tap: a close mark in red on a red tint.
private struct DisconnectControl: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        Image(systemName: "xmark")
            .font(QuickControlStyle.iconFont)
            .foregroundStyle(Color.red)
            .frame(width: QuickControlStyle.height, height: QuickControlStyle.height)
            .background(Circle().fill(Color.red.opacity(0.18)))
            .contentShape(Circle())
            .onTapGesture { client.disconnect() }
            .accessibilityElement()
            .accessibilityLabel(client.macName.isEmpty ? "Disconnect" : "Disconnect from \(client.macName)")
            .accessibilityAddTraits(.isButton)
    }
}

/// The Mac's clipboard: a plain clipboard while there is nothing new from the Mac, a full one, lit,
/// once the Mac has copied text, and a tap puts that text on this device's clipboard (a tick for a
/// moment). Dimmed while the Mac shares no clipboard or this device's Share Clipboard is off.
private struct ClipboardControl: View {
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
            .frame(width: QuickControlStyle.height, height: QuickControlStyle.height)
            .background(Circle().fill(waiting ? Color.white : QuickControlStyle.fill))
            .contentShape(Circle())
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

/// Retina (the Mac's pixels, 2×) or Standard (its points, 1×), through the Settings panel's path.
private struct ResolutionControl: View {
    @ObservedObject var client: StreamClient
    let captureScale: Double

    var body: some View {
        FlipToggle(options: [1.0, 2.0], selection: captureScale >= 1.5 ? 2.0 : 1.0,
                   label: { $0 >= 1.5 ? "Retina" : "Standard" },
                   icon: { $0 >= 1.5 ? "desktopcomputer" : "display" }, accessibilityLabel: "Resolution") { scale in
            client.changeSettings(HostSettingsChange(captureScale: scale))
        }
    }
}

/// The Mac's frame rate limit, 60 or 120 fps (the stream runs at the most a device's screen shows),
/// through the Settings panel's path.
private struct FrameRateControl: View {
    @ObservedObject var client: StreamClient
    let maxFPS: Int

    var body: some View {
        FlipToggle(options: SettingsChoices.maxFPS.sorted(), selection: maxFPS,
                   label: { "\($0) fps" },
                   icon: { $0 > 60 ? "film.stack" : "film" }, accessibilityLabel: "Frame Rate") { fps in
            client.changeSettings(HostSettingsChange(maxFPS: fps))
        }
    }
}

/// The Mac's streaming quality, through the Settings panel's own path (`changeSettings`): a pick
/// shows at once and goes back if the Mac refuses it or never answers. A bitrate set by hand on
/// the Mac is "Custom", shown and never offered.
private struct QualityControl: View {
    @ObservedObject var client: StreamClient
    /// What the Mac streams at, or this device's pick while the Mac has not answered it.
    let bitrate: Int

    /// DEBUG `-SillQualityDemo pro`: the picker opens and picks that preset by itself.
    private static var demo: QualityPreset? {
        #if DEBUG
        let name = UserDefaults.standard.string(forKey: "SillQualityDemo")
        return QualityPreset.allCases.first { $0.name.lowercased() == name?.lowercased() }
        #else
        return nil
        #endif
    }

    /// A speed dial whose needle climbs with the preset (Custom: the middle).
    private static func gauge(_ preset: QualityPreset?) -> String {
        let all = QualityPreset.allCases
        guard let preset, let i = all.firstIndex(of: preset), all.count > 1 else {
            return "gauge.with.dots.needle.50percent"
        }
        let at = Double(i) / Double(all.count - 1) * 100
        let level = [0, 33, 50, 67, 100].min { abs(Double($0) - at) < abs(Double($1) - at) }!
        return "gauge.with.dots.needle.\(level)percent"
    }

    var body: some View {
        MorphingPicker(options: QualityPreset.allCases,
                       selection: QualityPreset(rawValue: bitrate),
                       label: \.name,
                       accessibilityLabel: "Quality",
                       accessibilityLabelFor: \.title,
                       icon: Self.gauge,
                       startsOpen: UserDefaults.standard.bool(forKey: "SillQualityOpen"),
                       demo: Self.demo) { preset in
            client.changeSettings(HostSettingsChange(bitrate: preset.rawValue))
        }
    }
}
