import SwiftUI
import StreamProtocol

/// The iPhone's Settings sheet (PhoneControlBar's Settings), a RisingSheet, one row each: Resolution,
/// Frame Rate and Quality laid out open at once (ChoiceTrack), Touch or Trackpad, the Mac's sound
/// (MacSoundControl, pinned open), then its clipboard, its screen off (for a Mac that has it) and,
/// while an extended display streams, its size. The three settings are the Mac's own, as on the iPad
/// (QuickControls); Touch or Trackpad is this device's. Open, it is the screen's open control
/// (QuickPillFocus): a touch anywhere else puts it away. Taller than its room, it scrolls.
struct PhoneSettingsSheet: View {
    @ObservedObject var client: StreamClient
    @Binding var open: Bool
    @Binding var trackpadInput: Bool
    let width: CGFloat
    let maxHeight: CGFloat
    /// The room this screen gives the picture: an extended display's default size.
    let displayRoom: CGSize

    private static let padding: CGFloat = 20
    private static let spacing: CGFloat = 10

    private var shownDisplay: ExtendedDisplay? {
        guard case .display(let id) = client.active else { return nil }
        return client.extendedDisplays.first { $0.id == id }
    }

    /// Input, the sound and the clipboard's row, after the three settings when the Mac has said them.
    private var height: CGFloat {
        let rows: CGFloat = client.settings.displayed == nil ? 3 : 6
        return min(rows * QuickControlStyle.height + (rows - 1) * Self.spacing + 2 * Self.padding, maxHeight).rounded()
    }

    var body: some View {
        RisingSheet(open: $open, width: width, height: height, focusID: "Settings") {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Self.spacing) {
                    if let shown = client.settings.displayed {
                        ChoiceTrack(options: [1.0, 2.0], selection: shown.captureScale >= 1.5 ? 2.0 : 1.0,
                                    label: { $0 >= 1.5 ? "Retina" : "Standard" }, icon: "display",
                                    accessibilityLabel: "Resolution") { scale in
                            client.changeSettings(HostSettingsChange(captureScale: scale))
                        }
                        ChoiceTrack(options: SettingsChoices.maxFPS.sorted(), selection: shown.maxFPS,
                                    label: { "\($0) fps" }, icon: "film", accessibilityLabel: "Frame Rate") { fps in
                            client.changeSettings(HostSettingsChange(maxFPS: fps))
                        }
                        ChoiceTrack(options: QualityPreset.allCases, selection: QualityPreset(rawValue: shown.bitrate),
                                    label: \.name, icon: "gauge.with.dots.needle.67percent",
                                    accessibilityLabel: "Quality") { preset in
                            client.changeSettings(HostSettingsChange(bitrate: preset.rawValue))
                        }
                    }
                    ChoiceTrack(options: [false, true], selection: trackpadInput,
                                label: { $0 ? "Trackpad" : "Touch" }, icon: trackpadInput ? "cursorarrow" : "hand.tap",
                                accessibilityLabel: "Input") { trackpadInput = $0 }
                    MacSoundControl(client: client, pinned: true)
                    HStack(spacing: 8) {
                        ClipboardControl(client: client)
                        if client.hostHasCurtain {
                            CurtainToggle(client: client)
                        }
                        if let display = shownDisplay {
                            DisplaySizeControl(client: client, display: display, room: displayRoom)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(Self.padding)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The iPhone's Keys sheet (PhoneControlBar's Keys), a RisingSheet: the key row in two rows
/// (KeyCaps). Like the iPad's key row it stays up while the picture is used, so a held modifier can
/// go with a click, until its icon puts it away or another sheet takes its place (DesktopScreen).
struct PhoneKeysSheet: View {
    @ObservedObject var client: StreamClient
    @Binding var open: Bool
    @Binding var latched: KeyModifiers
    let width: CGFloat
    let maxHeight: CGFloat

    private static let padding: CGFloat = 20

    private var height: CGFloat {
        min(KeyCaps.height(rows: 2) + 2 * Self.padding, maxHeight).rounded()
    }

    var body: some View {
        RisingSheet(open: $open, width: width, height: height) {
            KeyCaps(client: client, latched: $latched, rows: 2)
                .padding(Self.padding)
        }
        // Put away, it holds nothing: a latch nobody can see would surprise the next tap.
        .onChange(of: open) { _, isOpen in if !isOpen { latched = [] } }
    }
}

/// One choice among a few, laid out open: an open MorphingPicker's look without the morph, for the
/// iPhone's sheets, where every setting shows at once. The icon, then a track of every choice with
/// the current one lit; a tap picks, and the light slides to it. Wider than its room (Quality's
/// seven), it scrolls sideways, kept on the current choice.
struct ChoiceTrack<Value: Hashable>: View {
    let options: [Value]
    /// The current choice; nil when it is none of `options` (nothing lit).
    let selection: Value?
    let label: (Value) -> String
    let icon: String
    let accessibilityLabel: String
    let onPick: (Value) -> Void

    @Namespace private var light

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(QuickControlStyle.iconFont)
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: QuickControlStyle.height, height: QuickControlStyle.height)
                .accessibilityHidden(true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(options, id: \.self) { option in choice(option) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .clipShape(Capsule())
                .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
                .onChange(of: selection) { _, new in
                    if let new { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
        }
        .frame(height: QuickControlStyle.height)
        .background(Capsule().fill(QuickControlStyle.fill))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func choice(_ option: Value) -> some View {
        let lit = option == selection
        return Text(label(option))
            .font(QuickControlStyle.font)
            .foregroundStyle(lit ? Color.black : Color.white)
            .padding(.horizontal, QuickControlStyle.labelPadding)
            .frame(minWidth: QuickControlStyle.height, minHeight: QuickControlStyle.height)
            .background {
                if lit { Capsule().fill(Color.white).matchedGeometryEffect(id: "light", in: light) }
            }
            .contentShape(Capsule())
            .onTapGesture { pick(option) }
            .id(option)
            .accessibilityLabel(label(option))
            .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick(option) }
    }

    private func pick(_ option: Value) {
        guard option != selection else { return }
        withAnimation(.spring(duration: 0.28, bounce: 0.1)) { onPick(option) }
    }
}
