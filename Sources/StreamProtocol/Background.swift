import Foundation

/// The background link (docs/background-plan.md): one connection per connected Mac, beside any stream
/// session, at ALPN `sill-bg/1` (`RemoteTLS.backgroundALPN`). It carries no catalog and no frames.
///
/// - The device says hello (kind 23), then sends `LinkJoin` (kind 55): who it is to push to and what
///   it wants. The Mac keeps that registration whether or not a link is up, and answers with
///   `LinkState` (kind 56).
/// - A ping (10) every `LinkJoin.pingEvery` keeps the link alive; the Mac echoes it (11).
/// - `LinkLeave` (kind 57) is the device's Disconnect: the Mac forgets it, stops whatever it did for
///   it and closes the link.
/// - Features ride on the link: the agents' query and report (54, 53), and their live events (58).
///
/// JSON, every field optional where it may be missing, later fields optional (HostSettings.swift's
/// rules).
public struct LinkJoin: Codable, Hashable, Sendable {
    /// Increasing per device process; `LinkState.answering` carries it back.
    public var token: Int?
    /// Where the Mac pushes to; nil while the device has no token (notifications off, or not yet
    /// registered).
    public var push: PushTarget?
    public var features: LinkFeatures

    public init(token: Int? = nil, push: PushTarget? = nil, features: LinkFeatures) {
        self.token = token; self.push = push; self.features = features
    }

    /// How often the device pings, seconds; a link silent for `silence` is gone.
    public static let pingEvery: TimeInterval = 15
    public static let silence: TimeInterval = 45
}

/// An APNs destination.
public struct PushTarget: Codable, Hashable, Sendable {
    /// The device token, lowercase hex.
    public var token: String
    /// `development` (a Debug build: APNs' sandbox) or `production`.
    public var environment: String
    /// The app's bundle id, APNs' topic.
    public var topic: String

    public init(token: String, environment: String, topic: String) {
        self.token = token; self.environment = environment; self.topic = topic
    }

    public static let development = "development", production = "production"
}

/// What the device wants from this Mac in the background. Later features add optional fields.
public struct LinkFeatures: Codable, Hashable, Sendable {
    /// A notification each time an agent's turn ends on this Mac.
    public var agentsNotify: Bool?

    public init(agentsNotify: Bool? = nil) { self.agentsNotify = agentsNotify }
}

/// The Mac's answer to a join.
public struct LinkState: Codable, Hashable, Sendable {
    public var answering: Int?
    public var registered: Bool
    /// Why the Mac can't push: `noKey` (no APNs key on this Mac), `rejected` (APNs refused the last
    /// push to this device's token, so the Mac dropped it).
    public var pushProblem: String?

    public init(answering: Int?, registered: Bool, pushProblem: String? = nil) {
        self.answering = answering; self.registered = registered; self.pushProblem = pushProblem
    }

    public static let noKey = "noKey", rejected = "rejected"
}

/// The device's Disconnect.
public struct LinkLeave: Codable, Hashable, Sendable {
    public init() {}
}

/// Something an agent did, live on the link (and as a push's `sill` field).
public struct AgentEvent: Codable, Hashable, Sendable {
    /// `AgentProvider.id`.
    public var provider: String
    /// `AgentSession.id`.
    public var session: String
    public var title: String
    /// The folder's last part, "sill".
    public var project: String?
    /// `finished`.
    public var kind: String
    /// Seconds since 1970.
    public var at: Double

    public init(provider: String, session: String, title: String, project: String?, kind: String, at: Double) {
        self.provider = provider; self.session = session; self.title = title; self.project = project
        self.kind = kind; self.at = at
    }

    public static let finished = "finished"
}
