import Foundation
import Network
import StreamProtocol

/// Whether a saved Mac is online now, and how, for its card on the home screen
/// (docs/reachable-plan.md). Nearby, its Bonjour row says so (the network, Direct); otherwise
/// this check.
enum MacReach: Equatable {
    /// No answer yet: the first check is still running.
    case checking
    /// It answered with its own key, by this way ("Tailscale", "Wi‑Fi", RemoteDialPolicy.routeWord).
    case online(String)
    case offline
}

/// One check of a saved Mac through its remote door: its addresses in the dial's order
/// (RemoteDialPolicy.order), one at a time, TLS 1.3 as a session dial makes it (RemoteTLS, this
/// device's certificate, `sill/1`), pinned to the Mac's key. The handshake stops in the verify
/// block, whatever key answered, so the device never sends its certificate and nothing reaches
/// the Mac's sessions: no session, no catalog, no line in its log. The Mac counts a handshake the
/// device ended (-9825) as a peer that went away by itself, never toward its backoff
/// (DoorPolicy.handshakeRefusal), so checking every little while never locks this device out.
///
/// With `each`, every address is tried and its answer reported, the first online one still
/// settling `done` as soon as it answers: the routes the home screen's Connect menu and the info
/// panel list. Without it the check stops at the first.
///
/// The verify block sees the Mac's certificate, not yet its proof that it holds the key (TLS 1.3's
/// CertificateVerify comes after), so "online" means a machine at that address showed this Mac's
/// certificate. That is a hint for the card, never trust: a tap dials it pinned and the handshake
/// completes only with the key.
final class MacProbe {
    private let candidates: [RemoteDialPolicy.Candidate]
    private let pin: Data
    private let identity: RemoteIdentity
    private let done: (MacReach) -> Void
    private let each: ((RemoteDialPolicy.Candidate, Bool) -> Void)?
    /// Runs on the main queue once every address it will try has been, after `done` and each `each`;
    /// set before `start`.
    var onEnd: (() -> Void)?
    private let queue = DispatchQueue(label: "sill.probe", qos: .utility)
    // On `queue`.
    private var next = 0
    private var current: NWConnection?
    private var currentTimeout: DispatchWorkItem?
    private var finished = false
    /// `done` has run.
    private var answered = false
    /// The address being tried, and whether it showed the Mac's key.
    private var currentCandidate: RemoteDialPolicy.Candidate?
    private var currentHit = false

    /// Each address gets this long to show the Mac's key; a Mac at none of them is offline.
    static let attemptTimeout = 4.0

    /// `done` runs once and `each` once an address, on the main queue.
    init(candidates: [RemoteDialPolicy.Candidate], pin: Data, identity: RemoteIdentity,
         each: ((RemoteDialPolicy.Candidate, Bool) -> Void)? = nil, done: @escaping (MacReach) -> Void) {
        self.candidates = candidates
        self.pin = pin
        self.identity = identity
        self.each = each
        self.done = done
    }

    func start() { queue.async { self.tryNext() } }

    /// Stops it; `done` is not called. Any thread.
    func cancel() {
        queue.async {
            self.finished = true
            self.endCurrent()
        }
    }

    // MARK: On `queue`

    /// The address being tried is done with: its answer reported, then the next.
    private func advance() {
        if let c = currentCandidate, let each {
            let hit = currentHit
            DispatchQueue.main.async { each(c, hit) }
        }
        tryNext()
    }

    private func tryNext() {
        guard !finished else { return }
        endCurrent()
        currentCandidate = nil
        currentHit = false
        guard next < candidates.count else { return finish(.offline) }
        let candidate = candidates[next]
        next += 1
        guard candidate.port > 0, let port = NWEndpoint.Port(rawValue: UInt16(clamping: candidate.port)) else { return tryNext() }
        currentCandidate = candidate
        let held = WeakConnection()
        let tls = RemoteTLS.options(identity: identity.tls, role: .client(alpn: RemoteTLS.sessionALPN), verify: { [weak self] fp in
            // Called on `queue`. Never trusted: the handshake ends here either way.
            guard let self, !self.finished, held.connection === self.current else { return false }
            if fp == self.pin {
                let tunnel = held.connection?.currentPath?.usesInterfaceType(.other) ?? false
                let reach = MacReach.online(RemoteDialPolicy.routeWord(candidate, usedTunnel: tunnel))
                if self.each == nil { self.finish(reach) } else { self.currentHit = true; self.answer(reach) }
            }
            return false
        }, queue: queue)
        let c = NWConnection(host: NWEndpoint.Host(candidate.host), port: port, using: RemoteTLS.parameters(tls: tls, dialing: true))
        held.connection = c
        current = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.current else { return }
            switch state {
            // Waiting: no route to it now (a VPN that is off). Failed: refused, or the handshake
            // this check ended with another key.
            case .waiting, .failed: self.advance()
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, c === self.current else { return }
            self.advance()
        }
        currentTimeout = timeout
        queue.asyncAfter(deadline: .now() + Self.attemptTimeout, execute: timeout)
        c.start(queue: queue)
    }

    private func endCurrent() {
        currentTimeout?.cancel()
        currentTimeout = nil
        current?.stateUpdateHandler = nil
        current?.cancel()
        current = nil
    }

    private func finish(_ result: MacReach) {
        guard !finished else { return }
        finished = true
        endCurrent()
        answer(result)
        if let onEnd { DispatchQueue.main.async { onEnd() } }
    }

    private func answer(_ result: MacReach) {
        guard !answered else { return }
        answered = true
        let done = self.done
        DispatchQueue.main.async { done(result) }
    }
}

extension StreamClient {
    /// Checks each saved Mac at every saved address (`routeReach`, the Connect menu's routes), unless
    /// a check of it is running; none while a session or a dial runs (the Mac's door takes two
    /// connections from one source at a time while they are being admitted). The home screen calls
    /// it as it appears and every little while after. A Mac nearby is online by its row, so its
    /// check gives only its routes; one not nearby is online as its first address that answers
    /// (`reach`). Main thread.
    func checkSavedMacs() {
        guard !connected, connection == nil, remoteDial == nil else { return }
        let nearby = Set(macs.filter { $0.route != .remote }.compactMap(\.savedID))
        for mac in savedMacs {
            let id = mac.macID
            if nearby.contains(id) { reach[id] = nil }
            guard probes[id] == nil, mac.revoked != true, mac.newKey != true,
                  let pin = mac.fingerprintData, let identity = DeviceIdentity.existing() else { continue }
            let candidates = RemoteDialPolicy.order(mac.allAddresses, remotePort: mac.remotePort, lastWorked: mac.lastWorked,
                                                    localIPv4: Self.localIPv4Networks())
            if !nearby.contains(id), reach[id] == nil { reach[id] = .checking }
            let probe = MacProbe(candidates: candidates, pin: pin, identity: identity, each: { [weak self] c, ok in
                guard let self, self.probes[id] != nil else { return }
                self.routeReach[id, default: [:]][c.key] = ok
            }) { [weak self] result in
                guard let self, self.probes[id] != nil else { return }
                guard self.savedMac(id) != nil else { self.reach[id] = nil; return }
                if self.macs.contains(where: { $0.savedID == id && $0.route != .remote }) { self.reach[id] = nil; return }
                #if DEBUG
                if self.reach[id] != result { print("reach: \(self.displayName(id)) \(result)") }
                #endif
                self.reach[id] = result
            }
            probe.onEnd = { [weak self, weak probe] in
                guard let self, let probe, self.probes[id] === probe else { return }
                self.probes[id] = nil
            }
            probes[id] = probe
            probe.start()
        }
        // Forgotten Macs.
        for id in Array(reach.keys) where savedMac(id) == nil { reach[id] = nil }
        for id in Array(routeReach.keys) where savedMac(id) == nil { routeReach[id] = nil }
    }

    /// The home screen went away, or a dial starts: the checks stop.
    func stopCheckingSavedMacs() {
        probes.values.forEach { $0.cancel() }
        probes = [:]
        routeProbe?.cancel()
        routeProbe = nil
    }

    /// A saved Mac's addresses in the dial's order: the routes its Connect menu and the info panel
    /// list, keyed in `routeReach` by `Candidate.key`.
    func routes(_ macID: String) -> [RemoteDialPolicy.Candidate] {
        guard let mac = savedMac(macID) else { return [] }
        return RemoteDialPolicy.order(mac.allAddresses, remotePort: mac.remotePort, lastWorked: mac.lastWorked,
                                      localIPv4: Self.localIPv4Networks())
    }

    /// A route as the Connect menu and the info panel show it: one way to the Mac ("Tailscale",
    /// "Wi‑Fi") and every address of it, in the dial's order. Its IPv4 and IPv6 addresses are shown
    /// (a name only when it has no address).
    struct Route {
        let way: String
        /// IPv4 first, then IPv6.
        let displays: [String]
        /// A LAN address of the Mac's: the nearby row stands for it while there is one.
        let lan: Bool
        /// `Candidate.key`s: dialed together, in order.
        let keys: [String]
        /// Its addresses as they are dialed, without a port: what a connection's address is matched to.
        let hosts: [String]
        var id: String { way }

        /// Whether any of its addresses answered the last check: true if one did, false if all
        /// that were checked did not, nil before any answer.
        func reachable(_ checked: [String: Bool]) -> Bool? {
            let answers = keys.compactMap { checked[$0] }
            if answers.contains(true) { return true }
            return answers.count == keys.count && !answers.isEmpty ? false : nil
        }
    }

    /// `routes(macID)` grouped by their way, each group where its first address is in the dial's order.
    func groupedRoutes(_ macID: String) -> [Route] {
        var ways: [String] = []
        var groups: [String: [RemoteDialPolicy.Candidate]] = [:]
        for c in routes(macID) {
            let way = RemoteDialPolicy.routeWord(c, usedTunnel: false)
            if groups[way] == nil { ways.append(way) }
            groups[way, default: []].append(c)
        }
        return ways.map { way in
            let group = groups[way]!
            let addresses = group.filter { !$0.isName && !$0.isIPv6 } + group.filter(\.isIPv6)
            return Route(way: way, displays: (addresses.isEmpty ? group : addresses).map(\.display),
                         lan: group.contains { $0.kind == MacAddress.lan }, keys: group.map(\.key), hosts: group.map(\.host))
        }
    }

    /// The info panel opened: every address of this session's Mac checked, one at a time. The
    /// session's door is admitted already, and a check stops in the handshake, never a session.
    func checkSessionRoutes() {
        guard connected, routeProbe == nil, let id = session?.macID, let mac = savedMac(id),
              let pin = mac.fingerprintData, let identity = DeviceIdentity.existing() else { return }
        let probe = MacProbe(candidates: routes(id), pin: pin, identity: identity, each: { [weak self] c, ok in
            self?.routeReach[id, default: [:]][c.key] = ok
        }) { _ in }
        probe.onEnd = { [weak self, weak probe] in
            guard let self, let probe, self.routeProbe === probe else { return }
            self.routeProbe = nil
        }
        routeProbe = probe
        probe.start()
    }
}
