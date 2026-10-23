import Foundation
import Network
import StreamProtocol

/// One connected Mac's background link, this device's side (docs/background-plan.md): the Mac's saved
/// addresses dialed at its remote door, `sill-bg/1`, pinned to its key (RemoteConnector), then the
/// hello, and what MacLinks sends. A ping every `LinkJoin.pingEvery`; a link that brings nothing for
/// `LinkJoin.silence` is gone. A link that ends or never comes up dials again after 2, 4, 8, 16, then
/// every 30 s, until `stop`.
///
/// Every callback on the main queue. Its connection's work runs on `queue`.
final class BackgroundLink {
    enum State: Equatable {
        /// Dialing, or waiting to dial again.
        case linking
        case up
        /// Stopped (`stop`), or the Mac has no saved addresses to dial.
        case down
    }

    let macID: String
    private let mac: SavedMac
    private let identity: RemoteIdentity
    private let queue = DispatchQueue(label: "sill.link", qos: .utility)
    // On `queue`.
    private var connector: RemoteConnector?
    private var connection: NWConnection?
    private var heardAt = Date()
    private var pinger: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var failures = 0
    private var stopped = false

    /// On main.
    var onState: ((State) -> Void)?
    /// Each message from the Mac. On main.
    var onMessage: ((StreamMessageKind, Data) -> Void)?

    init(macID: String, mac: SavedMac, identity: RemoteIdentity) {
        self.macID = macID
        self.mac = mac
        self.identity = identity
    }

    func start() { queue.async { self.stopped = false; self.dial() } }

    /// Ends it, and any dial; nothing more is reported.
    func stop() {
        queue.async {
            self.stopped = true
            self.end()
        }
    }

    /// One message to the Mac, if the link is up (dropped otherwise: the next join says it all).
    func send(_ kind: StreamMessageKind, _ payload: Data) {
        queue.async { self.write(kind, payload) }
    }

    /// The device's Disconnect: up, or once it comes up, the leave (kind 57), then the end. `done`
    /// (main) with whether the Mac got it; a link that does not come up within `wait` gives up.
    func leave(wait: TimeInterval = 15, done: @escaping (Bool) -> Void) {
        queue.async {
            var finished = false
            let finish = { (ok: Bool) in
                guard !finished else { return }
                finished = true
                self.stopped = true
                self.end()
                DispatchQueue.main.async { done(ok) }
            }
            let sendLeave = {
                guard let c = self.connection else { return }
                let data = StreamMessage(kind: .linkLeave, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                         payload: Wire.encode(LinkLeave())).serialized()
                c.send(content: data, completion: .contentProcessed { error in self.queue.async { finish(error == nil) } })
            }
            if self.connection != nil { sendLeave(); return }
            self.onUp = sendLeave
            self.queue.asyncAfter(deadline: .now() + wait) { finish(false) }
            if self.connector == nil { self.stopped = false; self.dial() }
        }
    }

    /// A ping now, and a redial if the link went quiet meanwhile (the app comes back).
    func check() {
        queue.async {
            guard !self.stopped else { return }
            if self.connection == nil, self.connector == nil { self.retry?.cancel(); self.dial(); return }
            self.ping()
        }
    }

    // MARK: On `queue`

    /// Run once when the link comes up (a leave waiting for it).
    private var onUp: (() -> Void)?

    private func dial() {
        guard !stopped, connection == nil, connector == nil else { return }
        guard let pin = mac.fingerprintData else { report(.down); return }
        let candidates = RemoteDialPolicy.order(mac.allAddresses, remotePort: mac.remotePort, lastWorked: mac.lastWorked,
                                                localIPv4: StreamClient.localIPv4Networks())
        guard !candidates.isEmpty else { report(.down); return }
        report(.linking)
        let connector = RemoteConnector(candidates: candidates, mode: .background(pin: pin), identity: identity, queue: queue)
        self.connector = connector
        connector.onWinner = { [weak self, weak connector] winner in
            guard let self, self.connector === connector, !self.stopped else { winner.connection.cancel(); return }
            self.connector = nil
            self.adopt(winner.connection)
        }
        connector.onFailed = { [weak self, weak connector] _ in
            guard let self, self.connector === connector else { return }
            self.connector = nil
            self.again()
        }
        connector.start()
    }

    private func adopt(_ c: NWConnection) {
        connection = c
        failures = 0
        heardAt = Date()
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.lost(c) }
            default: break
            }
        }
        // The hello first, as on every session connection.
        let hello = StreamMessage(kind: .hello, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: StreamClient.helloPayload)
        c.send(content: hello.serialized(), completion: .contentProcessed { _ in })
        let reader = MessageReader(connection: c, stillReads: { [weak self] in self?.connection === c },
                                   onBytes: { [weak self] _ in self?.heardAt = Date() },
                                   onMessage: { [weak self] header, payload in
                                       guard header.kind != .pong else { return }
                                       DispatchQueue.main.async { self?.onMessage?(header.kind, payload) }
                                   },
                                   onEnd: { [weak self] _ in self?.lost(c) })
        reader.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + LinkJoin.pingEvery, repeating: LinkJoin.pingEvery)
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        pinger = timer
        #if DEBUG
        print("link: \(mac.name) up")
        #endif
        report(.up)
        let up = onUp
        onUp = nil
        up?()
    }

    private func ping() {
        guard let c = connection else { return }
        if Date().timeIntervalSince(heardAt) > LinkJoin.silence { c.cancel(); lost(c); return }
        var now = Date().timeIntervalSince1970.bitPattern.bigEndian
        write(.ping, Data(bytes: &now, count: 8))
    }

    private func write(_ kind: StreamMessageKind, _ payload: Data) {
        guard let c = connection else { return }
        let data = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: payload).serialized()
        c.send(content: data, completion: .contentProcessed { _ in })
    }

    private func lost(_ c: NWConnection) {
        guard connection === c else { return }
        connection = nil
        pinger?.cancel()
        pinger = nil
        c.cancel()
        #if DEBUG
        print("link: \(mac.name) down")
        #endif
        again()
    }

    /// The next dial, later: 2, 4, 8, 16, then every 30 s.
    private func again() {
        guard !stopped else { return }
        report(.linking)
        failures += 1
        let delay = min(30, pow(2, Double(min(failures, 5))))
        let item = DispatchWorkItem { [weak self] in self?.dial() }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func end() {
        retry?.cancel()
        retry = nil
        connector?.cancel()
        connector = nil
        pinger?.cancel()
        pinger = nil
        let c = connection
        connection = nil
        c?.cancel()
        report(.down)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { self.onState?(state) }
    }
}
