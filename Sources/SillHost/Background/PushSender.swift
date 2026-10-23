import CryptoKit
import Foundation
import StreamProtocol

/// Pushes to devices through APNs, straight from this Mac (docs/background-plan.md, "The push key"):
/// no server between. The key is Gabriel's APNs auth key, `AuthKey_<KEYID>.p8`, in
/// `~/Library/Application Support/Sill/Push/`, never in the repository; the team is JF8R4AVC2H unless
/// `push.json` there says `{"teamID": …}`. Without a key nothing is sent (`hasKey` false, which the
/// devices are told).
///
/// The provider token is ES256 over BackgroundPolicy's header and claims, made again every 50
/// minutes or when APNs refuses it. Requests go over HTTP/2 (URLSession), one per device.
///
/// Thread-safe: its state is behind a lock; `send`'s callback runs on URLSession's queue.
final class PushSender: @unchecked Sendable {
    private struct Key {
        let id: String
        let team: String
        let signing: P256.Signing.PrivateKey
    }

    private let folder: URL?
    private let lock = NSLock()
    private var key: Key?
    private var keyRead = false
    private var token: (value: String, at: Double)?
    private let session: URLSession

    static let defaultTeam = "JF8R4AVC2H"

    /// `folder` nil: never a key (a synthetic host).
    init(folder: URL?) {
        self.folder = folder
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    static var standardFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sill", isDirectory: true).appendingPathComponent("Push", isDirectory: true)
    }

    /// An APNs key is on this Mac (read once; a key added later counts after `reload`).
    var hasKey: Bool { lock.withLock { loadKey() != nil } }

    /// Reads the folder again on the next push (a key put there while Sill runs).
    func reload() { lock.withLock { keyRead = false; key = nil; token = nil } }

    /// One push; `done` gets the verdict, or nil when there is no key or no request could be made.
    func send(_ payload: Data, to target: PushTarget, collapse: String? = nil,
              done: @escaping @Sendable (BackgroundPolicy.PushVerdict?) -> Void) {
        guard let bearer = lock.withLock({ providerToken() }),
              let url = URL(string: "https://\(BackgroundPolicy.host(target.environment))/3/device/\(target.token)") else {
            done(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue(target.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        if let collapse { request.setValue(String(collapse.prefix(64)), forHTTPHeaderField: "apns-collapse-id") }
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let http = response as? HTTPURLResponse else { done(.lost); return }
            let reason = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["reason"] as? String
            let verdict = BackgroundPolicy.verdict(status: http.statusCode, reason: reason)
            if verdict == .newProviderToken { self?.lock.withLock { self?.token = nil } }
            if verdict != .delivered { print("Push: APNs answered \(http.statusCode)\(reason.map { " \($0)" } ?? "").") }
            done(verdict)
        }.resume()
    }

    // MARK: Under the lock

    private func loadKey() -> Key? {
        if keyRead { return key }
        keyRead = true
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        for name in names.sorted() {
            guard let id = BackgroundPolicy.keyID(fileName: name),
                  let pem = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                  let signing = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { continue }
            var team = Self.defaultTeam
            if let data = try? Data(contentsOf: folder.appendingPathComponent("push.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = object["teamID"] as? String, !t.isEmpty {
                team = t
            }
            key = Key(id: id, team: team, signing: signing)
            print("Push: APNs key \(id) for team \(team).")
            return key
        }
        return nil
    }

    private func providerToken() -> String? {
        guard let key = loadKey() else { return nil }
        let now = Date().timeIntervalSince1970
        if let token, now - token.at < BackgroundPolicy.providerTokenLife { return token.value }
        let input = BackgroundPolicy.providerTokenInput(keyID: key.id, teamID: key.team, issuedAt: now)
        guard let signature = try? key.signing.signature(for: Data(input.utf8)) else { return nil }
        let value = input + "." + BackgroundPolicy.base64url(signature.rawRepresentation)
        token = (value, now)
        return value
    }
}
