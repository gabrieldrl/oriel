import Foundation
import Network
import StreamProtocol

/// A feature of the background service: told the registrations as they change, and handed every
/// link message the server doesn't handle itself. Both on the server's queue; a feature that reads
/// or waits does so on a queue of its own.
protocol BackgroundFeature: AnyObject {
    func registrationsChanged(_ registry: BackgroundPolicy.Registry)
    /// True when the feature took the message.
    func received(_ kind: StreamMessageKind, _ payload: Data, from link: BackgroundServer.Link) -> Bool
}

/// The background service, the Mac's side (docs/background-plan.md): each connected device's
/// registration, kept until its Disconnect, and its live links at `sill-bg/1`, which both TLS doors
/// hand here (`serve`) and which never meet the stream.
///
/// - A link: the hello first (within 10 s), then joins, pings, a leave, and whatever its features
///   take (AgentsFeature: 53, 54, 58). A link silent for `LinkJoin.silence` is closed; a newer link
///   from the same device replaces it; at most `BackgroundPolicy.maxLinks` at once.
/// - The registrations (BackgroundPolicy): Sill.app keeps them in
///   `~/Library/Application Support/Sill/Background.json` (0600), so a restart keeps every connected
///   device; a synthetic host in memory only. A device unheard for 30 days is forgotten.
/// - Pushes go through PushSender; a token APNs says is gone is marked, and the device told.
///
/// Lines: one when a device's registration starts or changes what it wants, one at its Disconnect.
/// Threading: its state is on `queue`; connections run on the network queue and hop here.
final class BackgroundServer: @unchecked Sendable {
    /// One device's live link.
    final class Link: @unchecked Sendable {
        let connection: NWConnection
        /// The device's key fingerprint, hex: its registration's key.
        let device: String
        fileprivate(set) var name: String
        fileprivate let paired: Bool
        fileprivate var helloSeen = false
        fileprivate var heardAt = Date().timeIntervalSince1970

        fileprivate init(_ connection: NWConnection, device: String, name: String?) {
            self.connection = connection
            self.device = device
            self.name = name ?? ""
            paired = name != nil
        }

        /// One message to the device. Any thread.
        func send(_ kind: StreamMessageKind, _ payload: Data) {
            let data = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload).serialized()
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    let queue = DispatchQueue(label: "sill.background", qos: .utility)
    let macName: String
    /// This Mac's ID (its identity's), which the device's saved Mac carries: the push names the Mac.
    let macID: String?
    let push: PushSender
    private let file: URL?
    private var registry: BackgroundPolicy.Registry = [:]
    private var links: [ObjectIdentifier: Link] = [:]
    private var features: [BackgroundFeature] = []
    private var sweep: DispatchSourceTimer?
    private var lastExpiry = 0.0

    static let helloDeadline: TimeInterval = 10

    init(macName: String, macID: String?, synthetic: Bool) {
        self.macName = macName
        self.macID = macID
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sill", isDirectory: true)
        file = synthetic ? nil : support?.appendingPathComponent("Background.json")
        push = PushSender(folder: synthetic ? nil : PushSender.standardFolder)
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(BackgroundPolicy.Registry.self, from: data) {
            registry = BackgroundPolicy.current(saved, now: Date().timeIntervalSince1970)
            if !registry.isEmpty { print("Background: \(registry.count) connected device\(registry.count == 1 ? "" : "s") kept.") }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        sweep = timer
    }

    /// A feature, told the registrations at once (those kept from before may want it running).
    func add(_ feature: BackgroundFeature) {
        queue.async {
            self.features.append(feature)
            feature.registrationsChanged(self.registry)
        }
    }

    // MARK: From the doors (on the network queue)

    /// A paired device's link, admitted by its Door. `name`: its paired name.
    func serve(_ connection: NWConnection, fingerprint: Data, name: String?, queue netQueue: DispatchQueue) {
        let link = Link(connection, device: fingerprint.map { String(format: "%02x", $0) }.joined(), name: name)
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if case .failed = state { connection.cancel() }
                self?.queue.async { if self?.links[id] === link { self?.links[id] = nil } }
            default: break
            }
        }
        queue.async {
            if self.links.count >= BackgroundPolicy.maxLinks {
                connection.cancel()
                return
            }
            // A device has one link: a newer one replaces the old (the old one's socket may be stale).
            for (oldID, old) in self.links where old.device == link.device {
                self.links[oldID] = nil
                old.connection.cancel()
            }
            self.links[id] = link
            netQueue.asyncAfter(deadline: .now() + Self.helloDeadline) {
                self.queue.async { if self.links[id] === link, !link.helloSeen { self.close(link) } }
            }
            self.readNext(link)
        }
    }

    // MARK: What features ask (any thread)

    /// `payload` to every registered device that `wanting` picks and can be pushed to.
    func push(_ payload: Data, collapse: String?, wanting: @escaping @Sendable (BackgroundPolicy.Registration) -> Bool) {
        queue.async {
            for r in BackgroundPolicy.agentPushes(self.registry).filter(wanting) {
                guard let target = r.push else { continue }
                self.push.send(payload, to: target, collapse: collapse) { verdict in
                    guard verdict == .dropToken else { return }
                    self.queue.async { self.tokenGone(r.device, target.token) }
                }
            }
        }
    }

    /// One message on every live link whose registration `wanting` picks.
    func broadcast(_ kind: StreamMessageKind, _ payload: Data, wanting: @escaping @Sendable (BackgroundPolicy.Registration) -> Bool) {
        queue.async {
            for link in self.links.values {
                guard let r = self.registry[link.device], wanting(r) else { continue }
                link.send(kind, payload)
            }
        }
    }

    // MARK: On `queue`

    private func readNext(_ link: Link) {
        let c = link.connection
        c.receive(minimumIncompleteLength: StreamMessage.headerLength, maximumLength: StreamMessage.headerLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, let header = StreamMessage.parseHeader(data), header.payloadLength <= StreamMessage.maxClientPayload else {
                if isComplete || error != nil || data != nil { c.cancel() }
                return
            }
            let deliver = { (payload: Data) in
                self.queue.async {
                    guard self.links[ObjectIdentifier(c)] === link else { return }
                    if self.handle(header, payload, from: link) { self.readNext(link) }
                }
            }
            if header.payloadLength == 0 { deliver(Data()); return }
            c.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { data, _, _, _ in
                guard let data, data.count == header.payloadLength else { c.cancel(); return }
                deliver(data)
            }
        }
    }

    /// One message; false when the link is done.
    private func handle(_ header: StreamHeader, _ payload: Data, from link: Link) -> Bool {
        let now = Date().timeIntervalSince1970
        link.heardAt = now
        guard link.helloSeen || header.kind == .hello else { close(link); return false }
        registry = BackgroundPolicy.heard(registry, device: link.device, now: now)
        switch header.kind {
        case .hello:
            if !link.helloSeen, !link.paired, let hello = Wire.decode(Hello.self, from: payload) {
                link.name = SafeText.label(hello.device ?? "")
            }
            link.helloSeen = true
        case .ping:
            link.connection.send(content: StreamMessage(kind: .pong, timestamp: header.timestamp, isKeyframe: false, payload: payload).serialized(),
                                 completion: .contentProcessed { _ in })
        case .linkJoin:
            guard let join = Wire.decode(LinkJoin.self, from: payload) else { return true }
            let old = registry[link.device]
            registry = BackgroundPolicy.join(registry, device: link.device, name: link.name, join, now: now)
            if old?.features != join.features || (old?.push == nil) != (join.push == nil) {
                let who = link.name.isEmpty ? "A device" : link.name
                let notify = join.features.agentsNotify == true ? "on" : "off"
                print("Background: \(who) is connected (agent notifications \(notify)\(join.push == nil && join.features.agentsNotify == true ? ", no push token yet" : "")).")
            }
            saveAndTell()
            link.send(.linkState, Wire.encode(BackgroundPolicy.state(registry[link.device], answering: join.token, hasKey: push.hasKey)))
        case .linkLeave:
            let who = link.name.isEmpty ? "A device" : link.name
            if registry[link.device] != nil { print("Background: \(who) disconnected; nothing runs for it now.") }
            registry = BackgroundPolicy.leave(registry, device: link.device)
            saveAndTell()
            close(link)
            return false
        default:
            for feature in features where feature.received(header.kind, payload, from: link) { break }
        }
        return true
    }

    private func close(_ link: Link) {
        links[ObjectIdentifier(link.connection)] = nil
        link.connection.cancel()
    }

    private func tokenGone(_ device: String, _ token: String) {
        guard registry[device]?.push?.token == token else { return }
        registry[device]?.pushRejected = true
        print("Push: \(registry[device]?.name ?? "a device")'s token is gone; no more pushes until it sends another.")
        saveAndTell()
        for link in links.values where link.device == device {
            link.send(.linkState, Wire.encode(BackgroundPolicy.state(registry[device], answering: nil, hasKey: push.hasKey)))
        }
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        for link in links.values where now - link.heardAt > LinkJoin.silence { close(link) }
        if now - lastExpiry > 3600 {
            lastExpiry = now
            let current = BackgroundPolicy.current(registry, now: now)
            if current.count != registry.count {
                print("Background: \(registry.count - current.count) device(s) unheard for 30 days forgotten.")
                registry = current
                saveAndTell()
            }
        }
    }

    private func saveAndTell() {
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(registry) {
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        for feature in features { feature.registrationsChanged(registry) }
    }
}
