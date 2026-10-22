import SwiftUI

/// A quick control that steps through a few choices, one tap at a time: the closed pickers' pill
/// (QuickControlStyle) showing the current choice's icon and text, which roll up to the next and
/// down back to the first, however the choice changes (a tap, the Mac, a pointer device connecting):
/// the face follows `selection` with its own animation, so no caller has to animate it. Its width
/// follows the choice's text.
struct FlipToggle<Value: Hashable>: View {
    let options: [Value]
    /// The current choice; nil when it is none of `options`, and a tap then picks the first.
    let selection: Value?
    let label: (Value) -> String
    /// Each choice's SF Symbol.
    let icon: (Value) -> String
    let accessibilityLabel: String
    let onPick: (Value) -> Void

    private static var flip: Animation { .spring(duration: 0.35, bounce: 0.12) }

    private var index: Int? { selection.flatMap { options.firstIndex(of: $0) } }

    /// The choice the face shows: `selection`, set inside the roll's animation as it changes.
    @State private var shown: Value?
    /// A later choice rolls in from below, an earlier one from above.
    @State private var forward = true

    init(options: [Value], selection: Value?, label: @escaping (Value) -> String, icon: @escaping (Value) -> String,
         accessibilityLabel: String, onPick: @escaping (Value) -> Void) {
        self.options = options; self.selection = selection; self.label = label; self.icon = icon
        self.accessibilityLabel = accessibilityLabel; self.onPick = onPick
        _shown = State(initialValue: selection)
    }

    var body: some View {
        text
            .foregroundStyle(.white)
            .font(QuickControlStyle.font)
            .padding(.leading, QuickControlStyle.iconInset)
            .padding(.trailing, QuickControlStyle.labelPadding)
            .frame(minWidth: QuickControlStyle.height, minHeight: QuickControlStyle.height)
            .background(Capsule().fill(QuickControlStyle.fill))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { next() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(selection.map(label) ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { next() }
            .onChange(of: selection) { old, new in
                let from = old.flatMap { options.firstIndex(of: $0) } ?? -1
                forward = (new.flatMap { options.firstIndex(of: $0) } ?? 0) > from
                withAnimation(Self.flip) { shown = new }
            }
    }

    private var text: some View {
        ZStack(alignment: .leading) {
            if let shown {
                face(shown)
                    .id(shown)
                    .transition(.push(from: forward ? .bottom : .top))
            }
        }
    }

    /// The icon in the picker's slot, then the text, spaced as the picker's closed pill is.
    private func face(_ option: Value) -> some View {
        HStack(spacing: QuickControlStyle.iconSlot - QuickControlStyle.iconInset - QuickControlStyle.iconSize
                        + QuickControlStyle.labelPadding) {
            Image(systemName: icon(option))
                .font(QuickControlStyle.iconFont)
                .frame(width: QuickControlStyle.iconSize)
            Text(label(option))
        }
    }

    private func next() {
        guard !options.isEmpty else { return }
        let to = index.map { ($0 + 1) % options.count } ?? 0
        // The row makes room for the new width in the same spring.
        withAnimation(Self.flip) { onPick(options[to]) }
    }
}
