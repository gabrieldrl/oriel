import SwiftUI
import StreamProtocol

/// The small info button over the picture's top-right corner (DesktopScreen): a glass circle that
/// opens the info panel (InfoPanel) and is lit while it is up.
struct InfoButton: View {
    let open: Bool
    let onTap: () -> Void

    static let size: CGFloat = 30

    var body: some View {
        Image(systemName: "info")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(open ? Color.black : Color.white)
            .frame(width: Self.size, height: Self.size)
            .background { InfoGlass(shape: Circle(), lit: open) }
            .contentShape(Circle())
            .onTapGesture { onTap() }
            .animation(.easeOut(duration: 0.2), value: open)
            .accessibilityElement()
            .accessibilityLabel(open ? "Hide the stream's details" : "Show the stream's details")
            .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onTap() }
    }
}

/// What the stream is doing, in a glass panel at the picture's top-right corner: the round trip, the
/// frames' age, the frame rate, the bandwidth this device receives, the picture's size and the way to
/// the Mac. Every figure is the last second's (StreamClient.linkStats); "–" for a second without one.
/// Open, it is the screen's open control (QuickPillFocus): a touch anywhere else puts it away.
struct InfoPanel: View {
    @ObservedObject var client: StreamClient
    @Binding var open: Bool

    @Environment(\.quickPillFocus) private var focus
    @State private var frame: CGRect = .zero

    private static let id = "Info"
    static let width: CGFloat = 270

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(client.macName.isEmpty ? "Stream" : client.macName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            VStack(spacing: 7) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).foregroundStyle(.white.opacity(0.65))
                        Spacer(minLength: 12)
                        Text(row.value).monospacedDigit().multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .background { InfoGlass(shape: shape, lit: false) }
        .contentShape(shape)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(QuickPillFocus.space)) }) { f in
            frame = f
            focus?.moved(Self.id, to: f)
        }
        .onAppear {
            focus?.opened(Self.id) { open = false }
            focus?.moved(Self.id, to: frame)
        }
        .onDisappear { focus?.closed(Self.id) }
        .accessibilityElement(children: .contain)
    }

    private struct Row { let label: String; let value: String }

    private var rows: [Row] {
        let stats = client.linkStats
        let stream = client.settings.host?.stream
        var rows = [
            Row(label: "Latency", value: Self.spread(stats?.rtt)),
            Row(label: "Frame age", value: Self.spread(stats?.frameAge)),
            Row(label: "Frame rate", value: stats.map { "\($0.fps)" + (stream.map { " of \($0.fps)" } ?? "") + " fps" } ?? "–"),
            Row(label: "Bandwidth", value: stats.map { Self.mbps($0.bytes) + (stream.map { " of \($0.mbps)" } ?? "") + " Mbps" } ?? "–"),
            Row(label: "Resolution", value: Self.size(client.videoSize)),
        ]
        if let way = way { rows.append(Row(label: "Connection", value: way)) }
        return rows
    }

    /// How this session reaches the Mac: "Wi‑Fi", "Wired", "Direct", "through Tailscale".
    private var way: String? {
        if let remote = client.remoteRoute { return remote.phrase.prefix(1).uppercased() + remote.phrase.dropFirst() }
        return client.route?.word
    }

    /// "7 ms, worst 24".
    private static func spread(_ spread: StreamClient.MedianMax?) -> String {
        guard let spread else { return "–" }
        return spread.max > spread.median ? "\(spread.median) ms, worst \(spread.max)" : "\(spread.median) ms"
    }

    /// Bytes a second as megabits: "4.2", "38".
    private static func mbps(_ bytesPerSecond: Int) -> String {
        let mbps = Double(bytesPerSecond) * 8 / 1_000_000
        return mbps < 10 ? String(format: "%.1f", mbps) : "\(Int(mbps.rounded()))"
    }

    private static func size(_ size: CGSize) -> String {
        size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : "–"
    }
}

/// Liquid Glass on iOS 26, a dark material before it. Lit: white, as an open control's choice is.
private struct InfoGlass<S: Shape>: View {
    let shape: S
    let lit: Bool

    var body: some View {
        if lit {
            shape.fill(Color.white)
        } else if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
        }
    }
}
