import SwiftUI

/// The Mac's sound, which plays here and never on the Mac's speakers while Sill is connected
/// (StreamClient+Sound): a circle with a speaker and, around it, an arc as full as the Mac's volume;
/// silent (muted here and on the Mac, or the volume at nothing), red with a slashed speaker. A tap
/// opens it: the circle stays, now the mute, and a slider slides out beside it, white up to the
/// volume, a small speaker at one end and a loud one at the other; a drag anywhere on it sets the
/// Mac's volume, all the way down mutes, and up again unmutes. It folds back after 3 s untouched, or
/// at a touch anywhere else (QuickPillFocus). Dimmed while the Mac has no sound to give (a Mac before
/// it, or macOS refused).
struct MacSoundControl: View {
    @ObservedObject var client: StreamClient
    @Environment(\.quickPillFocus) private var focus
    @State private var open = false
    @State private var fold: Task<Void, Never>?

    private static let id = "Mac Sound"
    private static let sliderWidth: CGFloat = 188
    private static var morph: Animation { .spring(duration: 0.34, bounce: 0.12) }

    private var available: Bool { client.hostSendsSound && client.soundProblem == nil }
    private var silent: Bool { client.soundSilent }
    private var volume: Double { client.soundVolume }

    private var symbol: String {
        if silent { return "speaker.slash.fill" }
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: open ? 8 : 0) {
            circle
            slider
                .frame(width: open ? Self.sliderWidth : 0, height: QuickControlStyle.height, alignment: .leading)
                .clipShape(Capsule())
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
        }
        .reportsPillFrame(Self.id, to: focus, while: open)
        .opacity(available ? 1 : 0.4)
        .animation(Self.morph, value: open)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: silent)
        .onChange(of: available) { if !available { close() } }
        .onDisappear { close() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.id)
        .accessibilityValue(silent ? "Muted" : "\(Int((volume * 100).rounded())) percent")
        .accessibilityHint(available ? "" : client.soundProblem == nil ? "This Mac does not send its sound" : "The Mac could not share its sound")
        .accessibilityAdjustableAction { direction in
            guard available else { return }
            switch direction {
            case .increment: client.setSoundVolume(volume + 0.1)
            case .decrement: client.setSoundVolume(volume - 0.1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: silent ? "Unmute" : "Mute") { if available { client.toggleSoundMute() } }
        #if DEBUG
        // `-SillSoundOpen 1`: opens by itself, and stays, for photographs.
        .onAppear { if UserDefaults.standard.bool(forKey: "SillSoundOpen") { openUp() } }
        #endif
    }

    /// The speaker, the arc of the volume around it; the mute once open.
    private var circle: some View {
        ZStack {
            if !silent {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 2.5)
                    .padding(5)
                Circle()
                    .trim(from: 0, to: volume)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                    .animation(.easeOut(duration: 0.12), value: volume)
            }
            Image(systemName: symbol)
                .font(QuickControlStyle.iconFont)
                .foregroundStyle(silent ? Color.red : Color.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .quickCircle(silent ? Color.red.opacity(0.18) : QuickControlStyle.fill)
        .onTapGesture {
            guard available else { return }
            if open { client.toggleSoundMute() } else { openUp() }
            armFold()
        }
    }

    /// The track, white up to the volume; its speakers dark over the white and light over the track.
    private var slider: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let filled = CGFloat(silent ? 0 : volume) * width
            ZStack(alignment: .leading) {
                Capsule().fill(QuickControlStyle.fill)
                Rectangle().fill(Color.white).frame(width: filled)
                speakers(Color.white)
                speakers(Color.black)
                    .mask(alignment: .leading) { Rectangle().frame(width: filled) }
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    fold?.cancel()
                    client.setSoundVolume(Double(drag.location.x / width))
                }
                .onEnded { _ in armFold() })
        }
    }

    private func speakers(_ color: Color) -> some View {
        HStack {
            Image(systemName: "speaker.fill").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .frame(width: Self.sliderWidth, height: QuickControlStyle.height)
    }

    private func openUp() {
        guard !open else { return }
        open = true
        focus?.opened(Self.id) { close() }
    }

    private func armFold() {
        fold?.cancel()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SillSoundOpen") { return }
        #endif
        fold = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { close() }
        }
    }

    private func close() {
        fold?.cancel()
        open = false
        focus?.closed(Self.id)
    }
}
