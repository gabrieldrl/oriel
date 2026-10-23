import SwiftUI
import StreamProtocol

/// The row of quick controls under the Mac's picture on the new main screen (DesktopScreen),
/// across the picture's width, built from the shared pieces in this folder (FlipToggle,
/// MorphingPicker, QuickControlStyle, QuickPillFocus): Resolution, Frame Rate, then Quality, which
/// moves along whatever comes after it when it opens, and while an extended display streams its size
/// (DisplaySizeControl); Apps in the middle (AppsPill), with Displays
/// beside it (DisplaysPill); at the trailing edge Touch or Trackpad, the
/// Mac’s sound (MacSoundControl), typing (TypingControl: the keyboard and the key row), its clipboard (ClipboardControl), its
/// screen off (CurtainControl) and Disconnect. The settings
/// controls and Disconnect are below; the sound and the clipboard have files of their own.
///
/// The three settings are the Mac's own, as its menu sets them: one stream serves every device, so
/// they apply to all of them, and Sill.app keeps them for later sessions. A device away from home
/// sets the Mac's away quality and resolution instead (DeviceSettings.applyingAway).
struct QuickControls: View {
    @ObservedObject var client: StreamClient
    /// Touch or trackpad input (DesktopScreen's).
    @Binding var trackpadInput: Bool
    /// Disconnect's tap: the screen's ripple, then the session's end (DesktopScreen).
    let onDisconnect: () -> Void
    /// The Apps pill (AppsPill): lit while the Apps sheet is up, and its tap.
    let appsOpen: Bool
    let onApps: () -> Void
    /// The Displays pill (DisplaysPill), beside Apps for a Mac that makes extended displays.
    let displaysOpen: Bool
    let onDisplays: () -> Void
    /// The typing pill (TypingControl): the on-screen keyboard is up, and the key row's sheet.
    let keyboardShown: Bool
    let onKeyboard: () -> Void
    @Binding var keyRowOpen: Bool
    /// The room this screen gives the picture: an extended display's default size (DisplaySizeControl).
    let displayRoom: CGSize

    /// The extended display streaming, if one is.
    private var shownDisplay: ExtendedDisplay? {
        guard case .display(let id) = client.active else { return nil }
        return client.extendedDisplays.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 14) {
            if let shown = client.settings.displayed {
                ResolutionControl(client: client, captureScale: shown.captureScale)
                FrameRateControl(client: client, maxFPS: shown.maxFPS)
                QualityControl(client: client, bitrate: shown.bitrate)
            }
            if let display = shownDisplay {
                DisplaySizeControl(client: client, display: display, room: displayRoom)
            }
            Spacer(minLength: 0)
            AppsPill(open: appsOpen, onTap: onApps)
            if client.hostMakesDisplays {
                DisplaysPill(open: displaysOpen, onTap: onDisplays)
            }
            Spacer(minLength: 0)
            InputControl(trackpadInput: $trackpadInput)
            MacSoundControl(client: client)
            TypingControl(keyboardShown: keyboardShown, onKeyboard: onKeyboard, keyRowOpen: $keyRowOpen)
            ClipboardControl(client: client)
            if client.hostHasCurtain {
                CurtainControl(client: client)
            }
            DisconnectControl(client: client, onDisconnect: onDisconnect)
        }
        .frame(height: QuickControlStyle.height)
    }
}

/// The Mac's screen off, on a tap (StreamClient+Curtain): an open eye while the Mac shows its screen, a
/// closed one, lit, while it is dark and its own keyboard and trackpad do nothing. Orange when the Mac
/// could not (Sill may not control it: Accessibility).
private struct CurtainControl: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        let on = client.curtainOn
        let refused = client.curtainProblem != nil
        Image(systemName: on ? "eye.slash" : "eye")
            .font(QuickControlStyle.iconFont)
            .foregroundStyle(on ? Color.black : refused ? Color.orange : Color.white)
            .contentTransition(.symbolEffect(.replace))
            .quickCircle(on ? Color.white : QuickControlStyle.fill)
            .onTapGesture { client.setCurtain(!on) }
            .animation(.easeOut(duration: 0.2), value: on)
            .accessibilityElement()
            .accessibilityLabel("Mac's Screen Off")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityHint(refused ? "The Mac couldn’t: allow Oriel in Privacy & Security › Accessibility on the Mac."
                               : "Darkens the Mac and stops its own keyboard and trackpad while you work it from here.")
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Disconnect, on a tap: a close mark in red on a red tint. The screen ripples, then disconnects.
private struct DisconnectControl: View {
    @ObservedObject var client: StreamClient
    let onDisconnect: () -> Void

    var body: some View {
        Image(systemName: "xmark")
            .font(QuickControlStyle.iconFont)
            .foregroundStyle(Color.red)
            .quickCircle(Color.red.opacity(0.18))
            .onTapGesture { onDisconnect() }
            .accessibilityElement()
            .accessibilityLabel(client.macName.isEmpty ? "Disconnect" : "Disconnect from \(client.macName)")
            .accessibilityAddTraits(.isButton)
    }
}

/// Typing on the Mac, one pill of two columns (ColumnPill): the on-screen keyboard, and the key
/// row's sheet (KeyRowSheet) with the keys the keyboard lacks. Each is lit while it is up.
private struct TypingControl: View {
    let keyboardShown: Bool
    let onKeyboard: () -> Void
    @Binding var keyRowOpen: Bool

    var body: some View {
        ColumnPill(columns: [
            .init(id: "keyboard", icon: "keyboard", isOn: keyboardShown,
                  accessibilityLabel: keyboardShown ? "Hide the keyboard" : "Show the keyboard",
                  action: onKeyboard),
            .init(id: "keys", icon: KeyRowSheet.icon, isOn: keyRowOpen,
                  accessibilityLabel: keyRowOpen ? "Hide the key row" : "Show the key row",
                  action: { keyRowOpen.toggle() }),
        ])
    }
}

/// An extended display's size, on a tap: Default (the room this screen gives the picture, as a new
/// display gets) or Match Primary (the Mac's own display's size and scale). A round icon, and the
/// system's menu with the current one ticked; the display is made again at the pick and keeps streaming.
private struct DisplaySizeControl: View {
    @ObservedObject var client: StreamClient
    let display: ExtendedDisplay
    let room: CGSize

    var body: some View {
        let matching = Binding(get: { display.matchesPrimary == true },
                               set: { client.resizeDisplay(display.id, matchingPrimary: $0, room: room) })
        Menu {
            Picker("Display Size", selection: matching) {
                Text("Default").tag(false)
                Text("Match Primary").tag(true)
            }
        } label: {
            Image(systemName: "aspectratio")
                .font(QuickControlStyle.iconFont)
                .foregroundStyle(.white)
                .quickCircle()
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Display Size")
        .accessibilityValue(display.matchesPrimary == true ? "Match Primary" : "Default")
    }
}

/// Touch (a finger clicks where it lands) or Trackpad (the picture is a trackpad): this device's own
/// (DesktopScreen keeps it), rolling as Resolution does.
private struct InputControl: View {
    @Binding var trackpadInput: Bool

    var body: some View {
        FlipToggle(options: [false, true], selection: trackpadInput,
                   label: { $0 ? "Trackpad" : "Touch" },
                   icon: { $0 ? "cursorarrow" : "hand.tap" }, accessibilityLabel: "Input") { trackpadInput = $0 }
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
