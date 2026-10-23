import Foundation

// The background link (docs/background-plan.md), against Sources/StreamProtocol and the host's
// BackgroundPolicy.swift compiled into this binary (build.sh).
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }
typealias P = BackgroundPolicy

// MARK: - The wire

check(StreamMessageKind.linkJoin.rawValue == 55 && StreamMessageKind.linkState.rawValue == 56
      && StreamMessageKind.linkLeave.rawValue == 57 && StreamMessageKind.agentEvent.rawValue == 58, "kinds 55 to 58")
check(StreamMessageKind(rawValue: 59) == nil, "59 free")
check(RemoteTLS.backgroundALPN == "sill-bg/1", "the ALPN")
check(RemoteTLS.serverALPNs == ["sill/1", "sill-pair/1", "sill-bg/1"], "every host offers it beside the two that stay: \(RemoteTLS.serverALPNs)")
let push = PushTarget(token: "ab12", environment: PushTarget.development, topic: "com.gabrieldrl.sill")
let joinOn = LinkJoin(token: 4, push: push, features: LinkFeatures(agentsNotify: true))
check(json(joinOn) == #"{"features":{"agentsNotify":true},"push":{"environment":"development","token":"ab12","topic":"com.gabrieldrl.sill"},"token":4}"#,
      "a join: \(json(joinOn))")
check(json(LinkJoin(features: LinkFeatures())) == #"{"features":{}}"#, "a join wanting nothing")
check(Wire.decode(LinkJoin.self, from: Data(#"{"features":{"agentsNotify":false,"later":1},"later":true}"#.utf8))?.features.agentsNotify == false,
      "later fields are skipped")
check(json(LinkState(answering: 4, registered: true, pushProblem: LinkState.noKey)) == #"{"answering":4,"pushProblem":"noKey","registered":true}"#, "a state")
check(json(LinkLeave()) == "{}", "a leave is {}")
let event = AgentEvent(provider: "claude", session: "s1", title: "Fix it", project: "sill", kind: AgentEvent.finished, at: 100)
check(Wire.decode(AgentEvent.self, from: Wire.encode(event)) == event, "an event round-trips")
check(LinkJoin.pingEvery == 15 && LinkJoin.silence == 45, "a ping every 15 s, gone after 45 s")

// MARK: - Registrations

let off = LinkJoin(token: 1, push: push, features: LinkFeatures(agentsNotify: false))
var r = P.join([:], device: "aa", name: "iPad", joinOn, now: 10)
check(r["aa"]?.name == "iPad" && r["aa"]?.push == push && r["aa"]?.joinedAt == 10 && r["aa"]?.heardAt == 10, "a join registers")
check(P.watchesAgents(r) && P.agentPushes(r).map(\.device) == ["aa"], "it wants agents and can be pushed to")
r = P.join(r, device: "bb", name: "iPhone", off, now: 11)
check(P.agentPushes(r).map(\.device) == ["aa"], "only the devices that want it")
r = P.join(r, device: "aa", name: "iPad", off, now: 12)
check(!P.watchesAgents(r) && P.agentPushes(r).isEmpty, "a join replaces: none wants agents now, so nothing watches")
let noToken = LinkJoin(features: LinkFeatures(agentsNotify: true))
check(P.watchesAgents(P.join([:], device: "cc", name: "", noToken, now: 1)) && P.agentPushes(P.join([:], device: "cc", name: "", noToken, now: 1)).isEmpty,
      "wanting agents without a token: watched (the live link), never pushed")
check(P.heard(r, device: "aa", now: 50)["aa"]?.heardAt == 50 && P.heard(r, device: "aa", now: 50)["aa"]?.joinedAt == 12, "heard: only the time")
check(P.heard(r, device: "zz", now: 50) == r, "heard from a device with no registration: nothing made")
check(P.leave(r, device: "aa")["aa"] == nil && P.leave(r, device: "aa")["bb"] != nil, "a leave forgets that device alone")
let day = 86_400.0
let aged = P.join(P.join([:], device: "old", name: "", joinOn, now: 0), device: "new", name: "", joinOn, now: 29 * day)
check(P.current(aged, now: 30 * day + 1).keys.sorted() == ["new"], "30 days unheard: forgotten")
check(P.current(aged, now: 30 * day - 1).count == 2, "just under 30 days: kept")
check(P.expiry == 30 * day, "30 days")

var rejected = P.join([:], device: "aa", name: "", joinOn, now: 1)
rejected["aa"]?.pushRejected = true
check(P.agentPushes(rejected).isEmpty, "a rejected token is never pushed to")
check(P.join(rejected, device: "aa", name: "", joinOn, now: 2)["aa"]?.pushRejected == true, "the same token again: still rejected")
let fresh = LinkJoin(push: PushTarget(token: "cd34", environment: PushTarget.development, topic: "t"), features: LinkFeatures(agentsNotify: true))
check(P.join(rejected, device: "aa", name: "", fresh, now: 2)["aa"]?.pushRejected == nil, "a new token: pushed to again")

check(P.state(nil, answering: 3, hasKey: true) == LinkState(answering: 3, registered: false), "no registration")
check(P.state(r["bb"], answering: 3, hasKey: false) == LinkState(answering: 3, registered: true), "no key, but it wants no pushes: no problem")
check(P.state(P.join([:], device: "aa", name: "", joinOn, now: 1)["aa"], answering: nil, hasKey: false).pushProblem == LinkState.noKey, "no key on the Mac")
check(P.state(rejected["aa"], answering: nil, hasKey: true).pushProblem == LinkState.rejected, "a rejected token, said so")
check(P.state(P.join([:], device: "aa", name: "", joinOn, now: 1)["aa"], answering: nil, hasKey: true).pushProblem == nil, "all well")
check(P.maxLinks == 16, "16 links at most")

// MARK: - APNs

check(P.verdict(status: 200, reason: nil) == .delivered, "200 delivered")
check(P.verdict(status: 410, reason: "Unregistered") == .dropToken, "410: the token is gone")
check(P.verdict(status: 400, reason: "BadDeviceToken") == .dropToken && P.verdict(status: 400, reason: "DeviceTokenNotForTopic") == .dropToken,
      "a bad token, or another app's: gone")
check(P.verdict(status: 400, reason: "BadCollapseId") == .lost, "another 400: this push only")
check(P.verdict(status: 403, reason: "ExpiredProviderToken") == .newProviderToken && P.verdict(status: 403, reason: "InvalidProviderToken") == .newProviderToken,
      "a refused provider token: a new one")
check(P.verdict(status: 429, reason: "TooManyRequests") == .lost && P.verdict(status: 503, reason: nil) == .lost, "busy or failing: lost")
check(P.host(PushTarget.development) == "api.sandbox.push.apple.com" && P.host(PushTarget.production) == "api.push.apple.com",
      "the sandbox for a Debug build")
check(P.host("unknown") == "api.sandbox.push.apple.com", "anything else: the sandbox")
let input = P.providerTokenInput(keyID: "ABC123DEFG", teamID: "JF8R4AVC2H", issuedAt: 1_792_700_000.9)
let parts = input.split(separator: ".").map(String.init)
func unb64(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return String(decoding: Data(base64Encoded: t) ?? Data(), as: UTF8.self)
}
check(parts.count == 2 && unb64(parts[0]) == #"{"alg":"ES256","kid":"ABC123DEFG"}"#, "the token's header: \(parts.first.map(unb64) ?? "")")
check(parts.count == 2 && unb64(parts[1]) == #"{"iss":"JF8R4AVC2H","iat":1792700000}"#, "the token's claims, whole seconds")
check(!input.contains("=") && !input.contains("+") && !input.contains("/"), "base64url, no padding")
check(P.base64url(Data([0xfb, 0xff])) == "-_8", "base64url's alphabet")
check(P.providerTokenLife == 50 * 60, "a new provider token every 50 minutes")
check(P.keyID(fileName: "AuthKey_ABC123DEFG.p8") == "ABC123DEFG", "the key ID from the file's name")
check(P.keyID(fileName: "AuthKey_.p8") == nil && P.keyID(fileName: "key.p8") == nil && P.keyID(fileName: "AuthKey_AB/C.p8") == nil
      && P.keyID(fileName: "AuthKey_ABC.pem") == nil && P.keyID(fileName: "NotAKey_ABC123xyz") == nil, "anything else is no key")

let payload = P.agentPayload(event, agent: "Claude", macName: "Mac", macID: "M1")
let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
let aps = object["aps"] as? [String: Any] ?? [:]
let alert = aps["alert"] as? [String: Any] ?? [:]
check(alert["title"] as? String == "Claude finished" && alert["subtitle"] as? String == "sill · Mac" && alert["body"] as? String == "Fix it",
      "the alert: \(alert)")
check(aps["thread-id"] as? String == "M1" && aps["sound"] as? String == "default", "grouped per Mac, with the sound")
let sill = object["sill"] as? [String: Any] ?? [:]
check(sill["mac"] as? String == "M1" && sill["session"] as? String == "s1" && sill["provider"] as? String == "claude", "the event for the app: \(sill)")
let bare = (try? JSONSerialization.jsonObject(with: P.agentPayload(AgentEvent(provider: "codex", session: "x", title: "T", project: nil, kind: "finished", at: 1),
                                                                    agent: "Codex", macName: "Mac", macID: nil))) as? [String: Any] ?? [:]
let bareAPS = bare["aps"] as? [String: Any] ?? [:]
check((bareAPS["alert"] as? [String: Any])?["subtitle"] as? String == "Mac" && bareAPS["thread-id"] as? String == "Mac",
      "no folder: the Mac alone; no Mac ID: grouped by its name")

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
