import Foundation
import StreamProtocol

/// The background service's rules (docs/background-plan.md), pure: checked by Tests/checks/background.
///
/// - A device's registration is keyed by its key's fingerprint, made by its join, kept whether or not
///   a link is up, and ended only by its leave, by 30 days unheard (`expiry`), or by APNs saying its
///   token is gone.
/// - A push is an APNs request: the token's header and claims, the payload, and what an answer means.
enum BackgroundPolicy {
    /// One device's registration.
    struct Registration: Codable, Equatable, Sendable {
        /// The device's key fingerprint, hex.
        var device: String
        /// Its paired name, else its hello's device name.
        var name: String
        var push: PushTarget?
        var features: LinkFeatures
        /// When it last joined, and when anything was last heard from it (seconds since 1970).
        var joinedAt: Double
        var heardAt: Double
        /// APNs refused its token (`LinkState.rejected`): no push until it joins with another one.
        var pushRejected: Bool?
    }

    typealias Registry = [String: Registration]

    /// A device unheard this long is forgotten.
    static let expiry: TimeInterval = 30 * 86_400

    /// A join: the registration made or replaced. A rejected token stays rejected while the device
    /// sends that same token again.
    static func join(_ registry: Registry, device: String, name: String, _ join: LinkJoin, now: Double) -> Registry {
        var out = registry
        let old = registry[device]
        let rejected = old?.pushRejected == true && old?.push?.token == join.push?.token
        out[device] = Registration(device: device, name: name, push: join.push, features: join.features,
                                   joinedAt: now, heardAt: now, pushRejected: rejected ? true : nil)
        return out
    }

    /// Anything from the device on a link (a ping, a query): it is still there.
    static func heard(_ registry: Registry, device: String, now: Double) -> Registry {
        guard registry[device] != nil else { return registry }
        var out = registry
        out[device]?.heardAt = now
        return out
    }

    static func leave(_ registry: Registry, device: String) -> Registry {
        var out = registry
        out[device] = nil
        return out
    }

    /// The registrations still current: those heard within `expiry`.
    static func current(_ registry: Registry, now: Double) -> Registry {
        registry.filter { now - $0.value.heardAt < expiry }
    }

    /// The devices that want a push when an agent finishes, and can get one.
    static func agentPushes(_ registry: Registry) -> [Registration] {
        registry.values.filter { $0.features.agentsNotify == true && $0.push != nil && $0.pushRejected != true }
            .sorted { $0.device < $1.device }
    }

    /// Some device wants to hear about agents: the Mac watches them.
    static func watchesAgents(_ registry: Registry) -> Bool {
        registry.values.contains { $0.features.agentsNotify == true }
    }

    /// The join's answer: what keeps this device from being pushed to.
    static func state(_ registration: Registration?, answering: Int?, hasKey: Bool) -> LinkState {
        guard let registration else { return LinkState(answering: answering, registered: false) }
        var problem: String?
        if registration.features.agentsNotify == true {
            if registration.pushRejected == true { problem = LinkState.rejected } else if !hasKey { problem = LinkState.noKey }
        }
        return LinkState(answering: answering, registered: true, pushProblem: problem)
    }

    // MARK: APNs

    /// What an APNs answer means for the device and for the sender.
    enum PushVerdict: Equatable, Sendable {
        case delivered
        /// The token is gone (the app deleted, or never this topic's): never push to it again.
        case dropToken
        /// The provider token was refused: make a new one; this push is lost.
        case newProviderToken
        /// APNs is busy or failing: this push is lost, the next may go.
        case lost
    }

    static func verdict(status: Int, reason: String?) -> PushVerdict {
        switch status {
        case 200: return .delivered
        case 410: return .dropToken
        case 400 where reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic": return .dropToken
        case 403 where reason == "ExpiredProviderToken" || reason == "InvalidProviderToken": return .newProviderToken
        default: return .lost
        }
    }

    static func host(_ environment: String) -> String {
        environment == PushTarget.production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    /// A provider token lives an hour at APNs; a new one every 50 minutes.
    static let providerTokenLife: TimeInterval = 50 * 60

    /// The provider token's signing input: base64url(header) "." base64url(claims).
    static func providerTokenInput(keyID: String, teamID: String, issuedAt: Double) -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(issuedAt))}"#
        return base64url(Data(header.utf8)) + "." + base64url(Data(claims.utf8))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The key ID from an APNs key file's name: `AuthKey_ABC123DEFG.p8` → `ABC123DEFG`.
    static func keyID(fileName: String) -> String? {
        guard fileName.hasPrefix("AuthKey_"), fileName.hasSuffix(".p8") else { return nil }
        let id = String(fileName.dropFirst("AuthKey_".count).dropLast(".p8".count))
        return !id.isEmpty && id.allSatisfy({ $0.isLetter || $0.isNumber }) ? id : nil
    }

    /// The notification for an agent's finished turn: "Claude finished", "sill · Mac", the session's
    /// title; grouped per Mac. `sill` carries the event, for the app.
    static func agentPayload(_ event: AgentEvent, agent: String, macName: String, macID: String?) -> Data {
        let subtitle = [event.project, macName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        var alert: [String: Any] = ["title": "\(agent) finished", "body": event.title]
        if !subtitle.isEmpty { alert["subtitle"] = subtitle }
        var sill: [String: Any] = ["provider": event.provider, "session": event.session, "kind": event.kind, "at": event.at]
        if let macID { sill["mac"] = macID }
        let payload: [String: Any] = [
            "aps": ["alert": alert, "sound": "default", "thread-id": macID ?? macName] as [String: Any],
            "sill": sill,
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    /// The most links at once, across devices: a link is cheap, but not free.
    static let maxLinks = 16
}
