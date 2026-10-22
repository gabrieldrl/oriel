import SwiftUI

/// One choice among a few, as a control that opens in place. Closed, a pill shows its icon and the
/// current choice. A tap grows the pill across into a track of every choice, the current one lit
/// where it sits, so what comes after the control in its row moves along. A pick slides the lit
/// thumb to it, holds there a moment, and the track shrinks back into the pill around the pick. The
/// icon shows only on the closed pill, beside the choice.
/// It is one shape throughout, never a fade between two views: one number, how open it is, sets
/// every frame of the morph (PickerTrack). Open, it is the screen's open control (QuickPillFocus): a
/// touch anywhere else closes it on the current choice, and another control opening closes it.
struct MorphingPicker<Value: Hashable>: View {
    let options: [Value]
    /// The current choice; nil when it is none of `options` (`closedLabel` then says what it is).
    let selection: Value?
    let label: (Value) -> String
    /// The closed pill's text when `selection` is nil.
    let closedLabel: String
    let accessibilityLabel: String
    /// A choice's VoiceOver label, when it says more than its text.
    let accessibilityLabelFor: (Value) -> String
    let onPick: (Value) -> Void
    /// The SF Symbol before the choices, for the current choice (nil: none of `options`).
    let icon: (Value?) -> String
    /// DEBUG: opens by itself 1 s after it appears and picks this 1.5 s later, for photographing
    /// each stage of the animation.
    let demo: Value?

    @State private var open: Bool
    /// Each choice's frame in the row, and the closed label's size, as laid out.
    @State private var frames: [Int: CGRect] = [:]
    @State private var closedSize: CGSize = .zero
    @State private var settling = false
    @Environment(\.quickPillFocus) private var focus

    init(options: [Value], selection: Value?, label: @escaping (Value) -> String, closedLabel: String = "Custom",
         accessibilityLabel: String, accessibilityLabelFor: @escaping (Value) -> String = { _ in "" },
         icon: @escaping (Value?) -> String, startsOpen: Bool = false, demo: Value? = nil,
         onPick: @escaping (Value) -> Void) {
        self.options = options; self.selection = selection; self.label = label; self.closedLabel = closedLabel
        self.accessibilityLabel = accessibilityLabel; self.accessibilityLabelFor = accessibilityLabelFor
        self.onPick = onPick
        self.icon = icon
        self.demo = demo
        _open = State(initialValue: startsOpen)
    }

    /// Grows the pill across.
    private static var opening: Animation { .spring(duration: 0.32 * slow, bounce: 0.1) }
    /// The thumb to a pick.
    private static var sliding: Animation { .spring(duration: 0.28 * slow, bounce: 0.1) }
    /// How long the thumb rests on a pick before the track closes.
    private static var hold: Double { 0.35 * slow }
    /// Shrinks the track back into the pill.
    private static var closing: Animation { .spring(duration: 0.38 * slow, bounce: 0.05) }
    /// DEBUG `-SillPickerSlow 5`: every step five times slower, to photograph it.
    private static var slow: Double {
        #if DEBUG
        max(UserDefaults.standard.double(forKey: "SillPickerSlow"), 1)
        #else
        1
        #endif
    }

    private var selectedIndex: Int? { selection.flatMap { options.firstIndex(of: $0) } }

    /// The pill's frame in the row's space: the current choice's, else the closed label's.
    private var thumb: CGRect {
        if let i = selectedIndex, let frame = frames[i] { return frame }
        return CGRect(x: QuickControlStyle.iconSlot, y: 0, width: closedSize.width, height: QuickControlStyle.height)
    }

    private var rowWidth: CGFloat { frames.values.map(\.maxX).max() ?? 0 }

    var body: some View {
        let thumb = self.thumb
        PickerTrack(progress: open ? 1 : 0, thumbX: thumb.minX, thumbWidth: thumb.width, rowWidth: rowWidth,
                    labels: options.map(label),
                    accessibilityLabels: options.map { accessibilityLabelFor($0).isEmpty ? label($0) : accessibilityLabelFor($0) },
                    selectedIndex: selectedIndex, closedLabel: closedLabel, icon: icon(selection),
                    tappable: open && !settling,
                    onFrame: { i, frame in if frames[i] != frame { frames[i] = frame } },
                    onClosedSize: { if closedSize != $0 { closedSize = $0 } },
                    onTap: { pick(options[$0]) })
            .contentShape(Capsule())
            .onTapGesture { openUp() }
            .reportsPillFrame(accessibilityLabel, to: focus, while: open)
            .accessibilityElement(children: open ? .contain : .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(selection.map(label) ?? closedLabel)
            .accessibilityAddTraits(open ? [] : .isButton)
            .accessibilityAction { openUp() }
        #if DEBUG
            .onAppear {
                guard let demo else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openUp() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 1.5 * Self.slow) { pick(demo) }
            }
        #endif
    }

    private func openUp() {
        guard !open else { return }
        withAnimation(Self.opening) { open = true }
        focus?.opened(accessibilityLabel) { close() }
    }

    /// Back into the pill around the current choice.
    private func close() {
        withAnimation(Self.closing) { open = false }
        settling = false
        focus?.closed(accessibilityLabel)
    }

    /// Slide to the pick, rest, then close. A pick of the current choice only rests and closes.
    private func pick(_ option: Value) {
        settling = true
        let moves = option != selection
        if moves { withAnimation(Self.sliding) { onPick(option) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (moves ? Self.hold + 0.25 * Self.slow : 0.15 * Self.slow)) {
            if open { close() }
        }
    }
}

/// What MorphingPicker draws, at one moment of the morph. SwiftUI hands it every in-between value of
/// `progress` (0 closed, 1 open) and of the thumb's place, and it lays everything out from those
/// itself: left to SwiftUI, the row's move and the frame's change animated apart, and the labels
/// slid twice as far as the thumb under them.
///
/// In the row's space the icon's slot comes first, then the choices. Closed, the window shows the
/// icon beside the current choice, with the thumb (the pill) around both; open, the window is the
/// choices alone, the icon gone, the thumb around the choice alone.
private struct PickerTrack: View, Animatable {
    var progress: CGFloat
    var thumbX: CGFloat
    var thumbWidth: CGFloat
    let rowWidth: CGFloat
    let labels: [String]
    let accessibilityLabels: [String]
    let selectedIndex: Int?
    let closedLabel: String
    let icon: String
    let tappable: Bool
    let onFrame: (Int, CGRect) -> Void
    let onClosedSize: (CGSize) -> Void
    let onTap: (Int) -> Void

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(thumbX, thumbWidth)) }
        set { progress = newValue.first; thumbX = newValue.second.first; thumbWidth = newValue.second.second }
    }

    /// The row's own space; the nearest one of this name is always this track's.
    private let space = "MorphingPicker.row"
    private let slot = QuickControlStyle.iconSlot

    var body: some View {
        // The springs overshoot a little; colours stay within their ends.
        let p = min(max(progress, 0), 1)
        let closed = 1 - progress
        // Closed, the window starts at the icon beside the choice; open, at the first choice, past
        // the icon's slot: the icon shows only on the closed pill, gone in the first half of the
        // opening and back in the second half of the closing.
        let start = (thumbX - slot) * closed + slot * progress
        let pill = CGRect(x: thumbX - slot * closed, y: 0, width: thumbWidth + slot * closed,
                          height: QuickControlStyle.height)
        let width = (thumbWidth + slot) + (rowWidth - 2 * slot - thumbWidth) * progress
        let iconShown = max(0, 1 - 2 * p)
        row(p)
            .background(alignment: .leading) { thumb(pill, p) }
            .overlay(alignment: .leading) {
                iconView(.white).offset(x: start + QuickControlStyle.iconInset).opacity(iconShown)
            }
            // Black where the thumb is, so a label turns black as the thumb slides under it.
            .overlay(alignment: .leading) {
                ink(start: start, iconShown: iconShown)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: pill.width, height: pill.height).offset(x: pill.minX)
                    }
                    .opacity(p)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .leading) {
                if selectedIndex == nil { closedText.offset(x: slot).opacity(1 - p) }
            }
            .offset(x: -start)
            .frame(width: max(width, 0), height: QuickControlStyle.height, alignment: .leading)
            .background(Capsule().fill(QuickControlStyle.fill))
            .clipShape(Capsule())
            .font(QuickControlStyle.font)
    }

    /// Closed, the pill is the track's own grey; open, white.
    private func thumb(_ pill: CGRect, _ p: CGFloat) -> some View {
        Capsule()
            .fill(Color(white: 0.16 + 0.84 * p))
            .frame(width: pill.width, height: pill.height)
            .offset(x: pill.minX)
            .opacity(selectedIndex == nil ? 1 - p : 1)
    }

    private func iconView(_ ink: Color) -> some View {
        Image(systemName: icon)
            .font(QuickControlStyle.iconFont)
            .foregroundStyle(ink)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: QuickControlStyle.iconSize, height: QuickControlStyle.height)
            .accessibilityHidden(true)
    }

    /// The icon's slot, then every choice at its own width, measured in the row's own space so the
    /// offset never moves the frames.
    private func row(_ p: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: slot, height: QuickControlStyle.height)
            ForEach(Array(labels.enumerated()), id: \.offset) { i, text in
                let lit = i == selectedIndex
                Text(text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, QuickControlStyle.labelPadding)
                    .frame(minWidth: QuickControlStyle.height, minHeight: QuickControlStyle.height)
                    .contentShape(Capsule())
                    .onTapGesture { onTap(i) }
                    // Closed or closing, a tap goes past the labels to the track (it opens it).
                    .allowsHitTesting(tappable)
                    // In late, so labels sliding past the icon have barely come in.
                    .opacity(lit ? 1 : p * p)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(space)) }) { onFrame(i, $0) }
                    .accessibilityLabel(accessibilityLabels[i])
                    .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { if tappable { onTap(i) } }
            }
        }
        .coordinateSpace(.named(space))
        // Its own width whatever the control's frame is at the moment, or a narrow pill squeezes it.
        .fixedSize()
    }

    /// The row again in black, the icon where it is drawn now, for the thumb to show.
    private func ink(start: CGFloat, iconShown: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: slot, height: QuickControlStyle.height)
            ForEach(Array(labels.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .foregroundStyle(.black)
                    .padding(.horizontal, QuickControlStyle.labelPadding)
                    .frame(minWidth: QuickControlStyle.height, minHeight: QuickControlStyle.height)
            }
        }
        .fixedSize()
        .overlay(alignment: .leading) {
            iconView(.black).offset(x: start + QuickControlStyle.iconInset).opacity(iconShown)
        }
    }

    private var closedText: some View {
        Text(closedLabel)
            .foregroundStyle(.white)
            .padding(.horizontal, QuickControlStyle.labelPadding)
            .frame(minWidth: QuickControlStyle.height, minHeight: QuickControlStyle.height)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { onClosedSize($0) }
            .allowsHitTesting(false)
    }
}
