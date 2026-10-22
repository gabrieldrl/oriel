import SwiftUI
import Network
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
/// Under them the Mac's addresses this device knows: the one this session runs on, and each saved
/// one with whether it answered a check made as the panel opens (StreamClient.checkSessionRoutes).
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
            if !addresses.isEmpty {
                Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
                Text("Addresses")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                VStack(spacing: 8) {
                    ForEach(addresses, id: \.id) { address in
                        AddressRow(address: address)
                    }
                }
            }
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
            client.checkSessionRoutes()
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

    /// One of the Mac's addresses: how it is reached, the address, and its state.
    struct Address {
        let id: String
        let way: String
        /// IPv4 first, then IPv6.
        let hosts: [String]
        /// "Connected", "Reachable", "No answer", "Checking…".
        let state: String
        let dot: Color
    }

    /// Each of the Mac's routes, its IPv4 and IPv6 under it ("Wi‑Fi", "Tailscale"), the one this session
    /// runs on "Connected". A nearby session's own address joins its route (by address, else the
    /// network's way), or stands alone first when no saved address is on that network.
    private var addresses: [Address] {
        let green = Color(red: 0.2, green: 0.82, blue: 0.4)
        let grey = Color(white: 0.45)
        let session = client.session
        let nearby = session?.route.isRemote == false
        let here = nearby ? Self.remoteHost(client.connection) : nil
        let routes = session?.macID.map { client.groupedRoutes($0) } ?? []
        let checked = session?.macID.flatMap { client.routeReach[$0] } ?? [:]
        let mine = routes.firstIndex { route in
            if let here { return route.hosts.contains(here) }
            return session?.candidate.map { route.keys.contains($0.key) } ?? false
        } ?? (nearby ? routes.firstIndex { $0.lan && $0.way == client.route?.word } : nil)
        var out: [Address] = []
        if let here, mine == nil {
            out.append(Address(id: "session", way: client.route?.word ?? "This network", hosts: [here], state: "Connected", dot: green))
        }
        for (i, route) in routes.enumerated() {
            if i == mine {
                // A nearby session may have reached an address the Mac does not list (IPv6 link-local).
                let hosts = route.displays + (here.map { route.hosts.contains($0) ? [] : [$0] } ?? [])
                out.append(Address(id: route.id, way: route.way, hosts: hosts, state: "Connected", dot: green))
                continue
            }
            switch route.reachable(checked) {
            case true?: out.append(Address(id: route.id, way: route.way, hosts: route.displays, state: "Reachable", dot: green))
            case false?: out.append(Address(id: route.id, way: route.way, hosts: route.displays, state: "No answer", dot: grey))
            case nil: out.append(Address(id: route.id, way: route.way, hosts: route.displays, state: "Checking…", dot: grey))
            }
        }
        return out
    }

    /// The address a connection reached, without an IPv6 zone: "192.168.1.20".
    private static func remoteHost(_ connection: NWConnection?) -> String? {
        guard case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return text.split(separator: "%").first.map(String.init)
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

/// One line of the panel's Addresses: the way and its state over the address.
private struct AddressRow: View {
    let address: InfoPanel.Address

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(address.dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(address.way).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Text(address.state).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                ForEach(address.hosts, id: \.self) { host in
                    Text(host)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Liquid Glass on iOS 26, a dark material before it. Lit: white, as an open control's choice is.
/// The home screen's card overlays use it too.
struct InfoGlass<S: Shape>: View {
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
