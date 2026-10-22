import SwiftUI
import StreamProtocol

/// The Apps pill in the quick controls' row (QuickControls), centred between the settings and the
/// rest, a pill like the others: its icon and "Apps". A tap opens the Apps sheet (AppsTray); while
/// it is up the pill is lit, as a picker's choice is.
struct AppsPill: View {
    let open: Bool
    let onTap: () -> Void

    var body: some View {
        QuickPillFace(icon: AppsTray.icon, text: "Apps")
            .quickPillFrame()
            .foregroundStyle(open ? Color.black : Color.white)
            .background(Capsule().fill(open ? Color.white : QuickControlStyle.fill))
            .contentShape(Capsule())
            .onTapGesture { onTap() }
            .animation(.easeOut(duration: 0.2), value: open)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Apps")
            .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onTap() }
    }
}

/// The Apps sheet, a RisingSheet over the picture: the Mac's open windows, each a preview with its
/// app's icon and name under it, and Return to Desktop while a window streams. A tap on a preview
/// streams that window. Open, it is the screen's open control (QuickPillFocus): a touch anywhere else
/// puts it away.
struct AppsTray: View {
    @ObservedObject var client: StreamClient
    @Binding var open: Bool
    /// The previews' corners: the Desktop's own on screen, so every picture reads as the same display.
    let previewRadius: CGFloat
    /// The Mac's picture on screen, which the sheet rises over.
    let picture: CGSize

    /// The previews' own height, as laid out: the sheet is as tall as it needs, up to the picture's.
    @State private var gridHeight: CGFloat = 0

    static let icon = "square.grid.2x2"
    private static let headerHeight: CGFloat = 72
    private static let padding: CGFloat = 24
    private static let spacing: CGFloat = 20
    private static let minCell: CGFloat = 200

    private var width: CGFloat { RisingSheetStyle.width(over: picture.width) }

    /// As tall as its previews, up to the picture's height less a margin at the top.
    private var openHeight: CGFloat {
        let room = max(picture.height - Self.padding, 0)
        return min(Self.headerHeight + max(gridHeight, 80) + Self.padding, room).rounded()
    }

    var body: some View {
        RisingSheet(open: $open, width: width, height: openHeight, focusID: "Apps") { content }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                grid
                    .padding(.horizontal, Self.padding)
                    .padding(.bottom, Self.padding)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        let content = h - Self.padding
                        if abs(gridHeight - content) > 0.5 { gridHeight = content }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The window streaming now, if one is.
    private var streamingWindow: WindowInfo? {
        guard case .window(let id) = client.active else { return nil }
        return client.windows.first { $0.id == id }
    }

    /// Apps, and while a window streams, Return to Desktop.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon).font(QuickControlStyle.iconFont)
            Text("Apps").font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 0)
            if streamingWindow != nil {
                Button { pick(.desktop) } label: {
                    Label("Return to Desktop", systemImage: "arrow.uturn.backward")
                        .font(QuickControlStyle.font)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(QuickControlStyle.fill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { toggle() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(QuickControlStyle.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Apps")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.padding)
        .frame(height: Self.headerHeight)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var grid: some View {
        let windows = client.orderedWindows
        if windows.isEmpty {
            Text(client.macName.isEmpty ? "No windows are open." : "No windows are open on \(client.macName).")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            let inner = width - 2 * Self.padding
            let count = max(2, Int((inner + Self.spacing) / (Self.minCell + Self.spacing)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: count),
                      alignment: .leading, spacing: Self.spacing) {
                ForEach(windows) { window in
                    AppPreview(image: client.thumbnails[window.id], icon: client.icons[window.bundleID],
                               name: window.appName, title: window.title, radius: previewRadius,
                               isActive: client.active == .window(window.id)) { pick(.window(window.id)) }
                }
            }
        }
    }

    private func toggle() { open.toggle() }

    private func pick(_ source: StreamSource) {
        if client.active != source { client.select(source) }
        open = false
    }
}

/// One picture in the Apps sheet: the window's preview at 16:10, then its app's icon and name under
/// it, lined up with its leading edge.
private struct AppPreview: View {
    let image: UIImage?
    let icon: UIImage?
    let name: String
    let title: String
    let radius: CGFloat
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .aspectRatio(1.6, contentMode: .fit)
                    .overlay { picture }
                    .clipShape(frame)
                    .overlay(frame.strokeBorder(isActive ? Palette.accent : Color.white.opacity(0.12),
                                                lineWidth: isActive ? 2 : 1))
                HStack(spacing: 8) {
                    AppIcon(image: icon, name: name, size: 22, radius: 5, fontSize: 10)
                    Text(name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + (title.isEmpty ? "" : ", \(title)") + (isActive ? ", showing now" : ""))
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Palette.panel
        }
    }
}
