import SwiftUI

/// One pill holding several controls side by side, one icon to a column (the typing pill's keyboard
/// and key row, QuickControls). Each column is its own button; a column that is on is lit as an open
/// picker's choice is (white, its icon black), and a thin line parts two columns that are both off.
struct ColumnPill: View {
    struct Column: Identifiable {
        let id: String
        let icon: String
        let isOn: Bool
        let accessibilityLabel: String
        let action: () -> Void
    }

    let columns: [Column]

    /// A column's width: the row's height, so a one-column pill is a circle.
    private static let width = QuickControlStyle.height
    /// How far a lit column's highlight sits inside the pill's edge.
    private static let inset: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                if index > 0 { divider(between: columns[index - 1], and: column) }
                Image(systemName: column.icon)
                    .font(QuickControlStyle.iconFont)
                    .foregroundStyle(column.isOn ? Color.black : Color.white)
                    .frame(width: Self.width, height: QuickControlStyle.height)
                    .background {
                        Capsule().fill(Color.white).padding(Self.inset).opacity(column.isOn ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { column.action() }
                    .accessibilityElement()
                    .accessibilityLabel(column.accessibilityLabel)
                    .accessibilityAddTraits(column.isOn ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { column.action() }
            }
        }
        .background(Capsule().fill(QuickControlStyle.fill))
        .animation(.easeOut(duration: 0.2), value: columns.map(\.isOn))
        .accessibilityElement(children: .contain)
    }

    /// The line between two columns, gone beside a lit one (its highlight parts them).
    private func divider(between left: Column, and right: Column) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 22)
            .opacity(left.isOn || right.isOn ? 0 : 1)
            .accessibilityHidden(true)
    }
}
