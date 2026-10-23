import SwiftUI
import StreamProtocol

/// The new home screen, while nothing is connected: the Macs this device paired with, each a card in
/// a thin outline of its Desktop as last seen (MacDesktops). Over the picture's bottom edge, a glass
/// label of its name and whether it is online and how: "Online · Wi‑Fi" while a network or Direct
/// row lists it, else as a check of its saved addresses found it ("Online · Tailscale", "Offline":
/// MacProbe, docs/reachable-plan.md); and Connect, which connects by the best way (nearby when it
/// is listed there, else remotely at its saved addresses, as a tap on the picture does), its
/// chevron a menu of every route: the nearby row and each saved address, with whether it answered
/// the last check. The card's own menu has Forget. Above them the status line (not the idle
/// "Looking for Macs…"); at the bottom, Add a Mac, a quick-control pill, whose sheet is the old connect
/// screen (ConnectScreen) on its pairing card, with the nearby Macs not yet paired under it. The
/// same sheet comes up by itself when a tap's ask makes a Mac show its code, and for an outside
/// pairing link. `-SillClassicScreen 1` shows the old connect screen in its place (ContentView).
struct HomeScreen: View {
    @ObservedObject var client: StreamClient
    @ObservedObject private var desktops = MacDesktops.shared
    @Environment(\.scenePhase) private var scenePhase

    private enum Sheet: Identifiable {
        /// Add a Mac: the pairing card.
        case add
        /// The home card for a tap's ask, or an outside link's confirmation: what ConnectScreen
        /// shows by itself.
        case pairing
        var id: Self { self }
    }
    @State private var sheet: Sheet?
    /// The card last tapped: its picture dims under a spinner while the dial runs.
    @State private var dialing: String?

    /// A card's shape until its Mac's picture gives its own: a 14-inch MacBook Pro's display.
    private static let aspect: CGFloat = 3024.0 / 1964.0
    private static let margin: CGFloat = 24
    /// The outline's room around the picture.
    private static let inset: CGFloat = 12
    /// How often the Macs not nearby are checked while this screen shows.
    private static let checkEvery: Duration = .seconds(20)

    /// Most recently connected first, then the newest paired.
    private var saved: [SavedMac] {
        client.savedMacs.sorted {
            ($0.lastConnectedAt ?? $0.pairedAt) > ($1.lastConnectedAt ?? $1.pairedAt)
        }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                statusLine
                    .padding(.top, 16)
                    .padding(.horizontal, Self.margin)
                Spacer(minLength: 16)
                if saved.isEmpty {
                    empty
                } else {
                    cards(in: geo.size)
                }
                Spacer(minLength: 16)
                AddMacPill { sheet = .add }
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $sheet) { which in
            ConnectScreen(client: client, adding: which == .add)
                .overlay(alignment: .topTrailing) {
                    Button("Done") { sheet = nil }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(20)
                }
                .background(Color.black.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        // A tap's ask makes the Mac show its code, or a pairing link came in: the card for it.
        .onChange(of: client.homeAsk) { _, ask in if ask?.phase == .shown, sheet == nil { sheet = .pairing } }
        .onChange(of: client.pendingLink) { _, link in if link != nil, sheet == nil { sheet = .pairing } }
        .onAppear { if client.pendingLink != nil || client.homeAsk?.phase == .shown { sheet = .pairing } }
        .onChange(of: client.connected) { _, up in
            if up { sheet = nil }
            dialing = nil
        }
        .onChange(of: client.status) { _, line in announce(line) }
        // Whether each Mac not nearby answers from afar: now, every little while, as a Mac leaves the
        // network's list, and as the app comes back.
        .task {
            while !Task.isCancelled {
                client.checkSavedMacs()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
        .onChange(of: client.macs) { _, _ in client.checkSavedMacs() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { client.checkSavedMacs() } }
        .onDisappear { client.stopCheckingSavedMacs() }
    }

    // MARK: The status line

    @ViewBuilder private var statusLine: some View {
        VStack(spacing: 6) {
            Text(idle ? " " : client.status)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // A Mac that no longer serves this version said so: where to get the new one.
            if let notice = client.notice, notice.storeLink, notice.text == client.status, let url = SillLinks.appStore {
                Link("Update Oriel in the App Store", destination: url)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: 560)
    }

    /// The search's own "Looking for Macs…" lines: not shown; the cards say what is found.
    private var idle: Bool {
        client.status == StreamClient.lookingOnNetwork || client.status == StreamClient.lookingNearby
    }

    /// Not the idle "Looking for Macs…" lines, which change as the search does.
    private func announce(_ line: String) {
        guard !line.isEmpty, line != StreamClient.lookingOnNetwork, line != StreamClient.lookingNearby else { return }
        AccessibilityNotification.Announcement(line).post()
    }

    // MARK: The cards

    /// One Mac: a big card in the middle. More: a row of smaller ones, scrolling sideways once they
    /// run past the screen's edge. Never so tall that the status line and the pill lose their room.
    private func cards(in size: CGSize) -> some View {
        let room = size.width - 2 * Self.margin
        let tallest = max(size.height - 220, 120) * Self.aspect
        let width = min(saved.count == 1 ? min(room * 0.62, 620) : min(room * 0.4, 420), tallest)
        return ScrollView(.horizontal) {
            HStack(spacing: 32) {
                ForEach(saved) { mac in card(mac, width: width) }
            }
            .padding(.horizontal, Self.margin)
            .frame(minWidth: size.width)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func card(_ mac: SavedMac, width: CGFloat) -> some View {
        let row = nearbyRow(for: mac.macID)
        let name = client.displayName(mac.macID)
        let busy = dialing == mac.macID && dialRunning
        let state = state(mac.macID, row: row)
        // The picture a little inside the outline, which follows its corners.
        let picture = width - 2 * Self.inset
        let radius = Self.cornerRadius(picture)
        return self.picture(mac.macID, busy: busy, dim: state.offline && !busy, radius: radius)
            .frame(width: picture, height: picture / Self.aspect)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onTapGesture { connect(mac) }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 10) {
                    label(name, state: state)
                    Spacer(minLength: 0)
                    connectButton(mac, row: row)
                }
                .padding(10)
            }
            .padding(Self.inset)
            .overlay(
                RoundedRectangle(cornerRadius: radius + Self.inset, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .contextMenu { menu(mac) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name), \(state.text)")
    }

    /// Big enough to read as rounded at a small card's size, never a pill.
    private static func cornerRadius(_ width: CGFloat) -> CGFloat { max(14, width * 0.04) }

    /// The Mac's name and its state, on glass over the picture's bottom-left corner.
    private func label(_ name: String, state: CardState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Circle()
                    .fill(state.dot)
                    .frame(width: 7, height: 7)
                Text(state.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .animation(.easeOut(duration: 0.2), value: state.text)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background { InfoGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), lit: false) }
        .accessibilityElement(children: .combine)
    }

    /// Connect, by the best way; the chevron's menu, by any one of them.
    private func connectButton(_ mac: SavedMac, row: FoundMac?) -> some View {
        HStack(spacing: 0) {
            Button { connect(mac) } label: {
                Text("Connect")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .accessibilityHint(row == nil ? "Connects through your VPN." : "Connects to this Mac.")
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1, height: 18)
            Menu {
                routesMenu(mac, row: row)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.leading, 11)
                    .padding(.trailing, 14)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Other ways to connect")
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .background { InfoGlass(shape: Capsule(), lit: false) }
    }

    /// Every way to this Mac: its nearby row, then each saved address in the dial's order (the
    /// network's own addresses left out while the row stands for them), each with whether it
    /// answered the last check.
    @ViewBuilder private func routesMenu(_ mac: SavedMac, row: FoundMac?) -> some View {
        let checked = client.routeReach[mac.macID] ?? [:]
        let routes = client.groupedRoutes(mac.macID).filter { row == nil || !$0.lan }
        Section("Connect through") {
            if let row {
                Button { dialing = mac.macID; client.stopCheckingSavedMacs(); client.connect(to: row) } label: {
                    Text(row.word ?? "This network")
                    Text(row.route == .direct ? "Nearby" : "This network")
                }
            }
            ForEach(routes, id: \.id) { route in
                Button {
                    dialing = mac.macID
                    client.stopCheckingSavedMacs()
                    client.connectRemotely(mac.macID, only: route.keys)
                } label: {
                    Text(route.way)
                    Text((route.displays + [Self.answer(route.reachable(checked))]).joined(separator: " · "))
                }
            }
        }
    }

    private static func answer(_ reachable: Bool?) -> String {
        switch reachable {
        case true?: return "Reachable"
        case false?: return "No answer"
        case nil: return "Checking…"
        }
    }

    /// The line under a card's name and its dot: online and how, offline, still checking, or what
    /// a tap on it nearby does first ("Not paired", "Update Oriel").
    private struct CardState {
        var text: String
        var dot: Color
        var offline = false
    }

    private func state(_ macID: String, row: FoundMac?) -> CardState {
        let online = Color(red: 0.2, green: 0.82, blue: 0.4)
        if let row {
            if case .method(let method) = row.homeWord {
                return CardState(text: method.map { "Online · \($0.word)" } ?? "Online", dot: online)
            }
            return CardState(text: row.word ?? "Online", dot: .orange)
        }
        switch client.reach[macID] {
        case .online(let way): return CardState(text: "Online · \(way)", dot: online)
        case .offline: return CardState(text: "Offline", dot: Color(white: 0.4), offline: true)
        case .checking, nil: return CardState(text: "Checking…", dot: Color(white: 0.4))
        }
    }

    /// The Mac's Desktop as last seen, or a stand-in until a session has shown it. Dimmed while the
    /// Mac is offline.
    private func picture(_ macID: String, busy: Bool, dim: Bool, radius: CGFloat) -> some View {
        ZStack {
            if let image = desktops.pictures[macID] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Palette.panel
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Palette.muted)
            }
            if busy {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.large).tint(.white)
            } else if dim {
                Color.black.opacity(0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: busy)
        .animation(.easeOut(duration: 0.3), value: dim)
    }

    /// The Mac's row nearby (the network, Direct), which a tap takes; nil when no browser lists it.
    private func nearbyRow(for macID: String) -> FoundMac? {
        client.macs.first { $0.savedID == macID && $0.route != .remote }
    }

    /// A dial is under way: its "Connecting to…" line, or the ask it started.
    private var dialRunning: Bool {
        client.status.hasPrefix("Connecting") || client.status.hasPrefix("Reconnecting") || client.homeAsk?.phase == .asking
    }

    private func connect(_ mac: SavedMac) {
        dialing = mac.macID
        client.stopCheckingSavedMacs()
        if let row = nearbyRow(for: mac.macID) {
            client.connect(to: row)
        } else {
            client.dialSaved(mac.macID, why: .tap)
        }
    }

    @ViewBuilder private func menu(_ mac: SavedMac) -> some View {
        Button { connect(mac) } label: { Label("Connect", systemImage: "play.display") }
        Button(role: .destructive) {
            MacDesktops.shared.forget(mac.macID)
            client.forget(mac.macID)
        } label: { Label("Forget \(client.displayName(mac.macID))", systemImage: "trash") }
    }

    /// No Mac paired yet.
    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 6)
            Text("No Macs yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text("Add a Mac once, then connect to it with a tap.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Self.margin)
    }
}

/// Add a Mac, as the quick controls' pills are.
private struct AddMacPill: View {
    let onTap: () -> Void

    var body: some View {
        QuickPillFace(icon: "plus", text: "Add a Mac")
            .quickPillFrame()
            .background(Capsule().fill(QuickControlStyle.fill))
            .contentShape(Capsule())
            .onTapGesture { onTap() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Add a Mac")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Pairs this \(StreamClient.deviceWord) with a Mac so you can reach it away from home.")
            .accessibilityAction { onTap() }
    }
}
