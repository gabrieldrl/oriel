import SwiftUI
import StreamProtocol

/// The new main screen's Apps tray: a black tab joined to the bottom edge's centre that morphs up
/// into a black card of the Mac's open windows, each a preview with its app's icon and name under
/// it. While the Desktop streams the tab says "Apps"; while a window does, it also names that
/// window's app and offers Return to Desktop. A tap on a preview streams that window. The tab and
/// the card are one shape whose size and corners animate, so the tab grows into the card.
struct AppsTray: View {
    @ObservedObject var client: StreamClient
    @Binding var open: Bool
    /// The previews' corners: the Desktop's own on screen, so every picture reads as the same display.
    let previewRadius: CGFloat
    /// The card's width: the whole screen.
    let fullWidth: CGFloat
    /// The home indicator's strip, which the open card's previews keep clear of.
    let bottomInset: CGFloat

    /// The tab's height from the screen's bottom edge; the screen keeps this much clear for it.
    static let tabHeight: CGFloat = 44
    /// A 12.9-inch iPad Pro's screen corners (iOS gives no public value), which the open card's
    /// bottom corners follow.
    static let deviceCorner: CGFloat = 18
    private static let previewHeight: CGFloat = 120
    /// The open card's margin at each side.
    private static let sideMargin: CGFloat = 40
    private static let spring = Animation.spring(duration: 0.42, bounce: 0.16)

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: open ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, open ? Self.sideMargin - 22 : 0)
            if open {
                previews
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
        .frame(width: open ? fullWidth : nil)
        .background { shape.fill(Color.black) }
        .overlay { shape.stroke(Color.white.opacity(0.09), lineWidth: 1) }
    }

    /// Closed, the tab's bottom meets the screen's straight edge; open, the card's follows its corners.
    private var shape: UnevenRoundedRectangle {
        let top: CGFloat = open ? 28 : 16
        let bottom: CGFloat = open ? Self.deviceCorner : 0
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }

    /// The window streaming now, if one is.
    private var streamingWindow: WindowInfo? {
        guard case .window(let id) = client.active else { return nil }
        return client.windows.first { $0.id == id }
    }

    /// Apps; and while a window streams, its app and Return to Desktop.
    private var header: some View {
        HStack(spacing: 0) {
            segment(action: toggle) {
                Label("Apps", systemImage: "square.grid.2x2")
            }
            .accessibilityLabel(open ? "Close Apps" : "Apps")
            if let window = streamingWindow {
                divider
                HStack(spacing: 8) {
                    AppIcon(image: client.icons[window.bundleID], name: window.appName,
                            size: 20, radius: 5, fontSize: 9)
                    Text(window.appName).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: Self.tabHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Showing \(window.appName)")
                divider
                segment(action: { pick(.desktop) }) {
                    Label("Return to Desktop", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 18)
    }

    private func segment<Content: View>(action: @escaping () -> Void,
                                        @ViewBuilder label: () -> Content) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 14)
                .frame(height: Self.tabHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var previews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(client.orderedWindows) { window in
                    AppPreview(image: client.thumbnails[window.id], icon: client.icons[window.bundleID],
                               name: window.appName,
                               aspect: CGFloat(max(window.width, 1)) / CGFloat(max(window.height, 1)),
                               height: Self.previewHeight, radius: previewRadius,
                               isActive: client.active == .window(window.id)) { pick(.window(window.id)) }
                }
            }
            .padding(.horizontal, Self.sideMargin)
            .padding(.top, 6)
            .padding(.bottom, max(bottomInset, 12) + 12)
        }
    }

    private func toggle() {
        withAnimation(Self.spring) { open.toggle() }
    }

    private func pick(_ source: StreamSource) {
        if client.active != source { client.select(source) }
        withAnimation(Self.spring) { open = false }
    }
}

/// One picture in the Apps card: the window's preview, then its app's icon and name under it,
/// lined up with its leading edge.
private struct AppPreview: View {
    let image: UIImage?
    let icon: UIImage?
    let name: String
    let aspect: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        let width = min(max(height * aspect, height * 0.7), height * 2.2)
        let frame = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                picture
                    .frame(width: width, height: height)
                    .clipShape(frame)
                    .overlay(frame.strokeBorder(isActive ? Palette.accent : Color.white.opacity(0.12),
                                                lineWidth: isActive ? 2 : 1))
                HStack(spacing: 6) {
                    AppIcon(image: icon, name: name, size: 20, radius: 5, fontSize: 9)
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + (isActive ? ", showing now" : ""))
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Palette.panel
        }
    }
}
