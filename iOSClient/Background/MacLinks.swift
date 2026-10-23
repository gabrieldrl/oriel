import Foundation
import StreamProtocol
import UIKit
import UserNotifications

/// The Macs this device is connected to, and the background service over each (docs/background-plan.md):
/// one for the app, whatever its windows.
///
/// - **Connected.** A stream session reaching a saved Mac connects it (`join`). Closing the stream
///   leaves it connected; Disconnect (`disconnect`) ends it. The connected Macs are kept, so the app
///   coming back finds them connected.
/// - **Links.** While the app is active, each connected Mac has a BackgroundLink, which sends this
///   device's join (its push token and what it wants) at every start and every change. The Mac keeps
///   that registration whether or not a link is up, until a Disconnect reaches it: a Disconnect while
///   the Mac is out of reach is kept (`leaving`) and sent when it next answers.
/// - **Agents.** "Get notified when an agent on any connected Mac finishes" (off by default), and
///   which Macs it covers (each saved Mac, unless turned off). Turning it on asks iOS for
///   notifications and registers for pushes; the token goes in every join.
/// - **Primitives for the agents' screens:** `askAgents` (a kind 54 on the link, its kind 53 into
///   `agentReports`), and each Mac's latest finished turn (`lastFinish`, from kind 58).
///
/// Main thread.
final class MacLinks: ObservableObject {
    static let shared = MacLinks()

    @Published private(set) var connected: [String]
    @Published private(set) var states: [String: BackgroundLink.State] = [:]
    /// Why a Mac can't push to this device (LinkState's `pushProblem`), as its last answer said.
    @Published private(set) var pushProblems: [String: String] = [:]
    @Published private(set) var agentsNotify: Bool
    /// The Macs turned off in Settings (each other one notifies while connected).
    @Published private(set) var agentsOff: Set<String>
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published private(set) var pushToken: String?
    @Published private(set) var agentReports: [String: AgentReport] = [:]
    @Published private(set) var lastFinish: [String: AgentEvent] = [:]

    private var leaving: Set<String>
    private var links: [String: BackgroundLink] = [:]
    private var leaves: [String: BackgroundLink] = [:]
    private var active = false
    private var token = 0

    private static let connectedKey = "Sill.connectedMacs"
    private static let leavingKey = "Sill.leavingMacs"
    private static let notifyKey = "Sill.agentsNotify"
    private static let offKey = "Sill.agentsNotifyOff"

    private init() {
        let d = UserDefaults.standard
        connected = d.stringArray(forKey: Self.connectedKey) ?? []
        leaving = Set(d.stringArray(forKey: Self.leavingKey) ?? [])
        agentsNotify = d.bool(forKey: Self.notifyKey)
        agentsOff = Set(d.stringArray(forKey: Self.offKey) ?? [])
        refreshPermission()
        if agentsNotify { UIApplication.shared.registerForRemoteNotifications() }
        // The app's state, not a window's: one store for all its windows.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MacLinks.shared.setActive(true)
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MacLinks.shared.setActive(false)
        }
        active = UIApplication.shared.applicationState == .active
    }

    // MARK: Connected Macs

    func isConnected(_ macID: String) -> Bool { connected.contains(macID) }

    /// A stream session reached this saved Mac: it is connected, and its link starts.
    func join(_ macID: String?) {
        guard let macID, savedMac(macID) != nil else { return }
        leaving.remove(macID)
        leaves[macID]?.stop()
        leaves[macID] = nil
        if !connected.contains(macID) {
            connected.append(macID)
            #if DEBUG
            print("links: \(macID) connected")
            #endif
        }
        persist()
        startLinks()
    }

    /// Disconnect: the Mac forgets this device and stops all it did for it; this device stops linking.
    func disconnect(_ macID: String) {
        connected.removeAll { $0 == macID }
        // The link that is up says the leave itself; else one is made for it.
        if let link = links.removeValue(forKey: macID) {
            leaves[macID]?.stop()
            leaves[macID] = link
            sendLeave(link, macID)
        }
        states[macID] = nil
        pushProblems[macID] = nil
        agentReports[macID] = nil
        lastFinish[macID] = nil
        leaving.insert(macID)
        persist()
        sendLeaves()
    }

    /// The app came to the front or left it. Links are made only while it is active (iOS closes them
    /// soon after it leaves); coming back each link is checked at once.
    func setActive(_ on: Bool) {
        guard on != active else {
            if on { links.values.forEach { $0.check() } }
            return
        }
        active = on
        if on {
            refreshPermission()
            #if DEBUG
            testFromLaunchArguments()
            #endif
            startLinks()
            links.values.forEach { $0.check() }
            sendLeaves()
        }
    }

    #if DEBUG
    /// `-SillAgentsNotify 1|0` sets the switch; `-SillDisconnectAll 1` disconnects every connected Mac
    /// (its leave said over a link of its own). Once, at the first activation.
    private var testsRan = false
    private func testFromLaunchArguments() {
        guard !testsRan else { return }
        testsRan = true
        let d = UserDefaults.standard
        if d.object(forKey: "SillAgentsNotify") != nil { setAgentsNotify(d.bool(forKey: "SillAgentsNotify")) }
        if d.bool(forKey: "SillDisconnectAll") { connected.forEach { disconnect($0) } }
    }
    #endif

    /// A Mac forgotten on this device: disconnected too.
    func forget(_ macID: String) {
        if connected.contains(macID) { disconnect(macID) }
    }

    // MARK: Agents

    func notifies(_ macID: String) -> Bool { agentsNotify && !agentsOff.contains(macID) }

    /// The switch in Settings. On: iOS is asked (once) and the device registers for pushes.
    func setAgentsNotify(_ on: Bool) {
        agentsNotify = on
        UserDefaults.standard.set(on, forKey: Self.notifyKey)
        if on {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    self.refreshPermission()
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                    self.sendJoins()
                }
            }
        } else {
            sendJoins()
        }
    }

    func setNotifies(_ macID: String, _ on: Bool) {
        if on { agentsOff.remove(macID) } else { agentsOff.insert(macID) }
        UserDefaults.standard.set(Array(agentsOff).sorted(), forKey: Self.offKey)
        if let link = links[macID] { link.send(.linkJoin, joinPayload(macID)) }
    }

    /// APNs gave this device its token (SillAppDelegate).
    func gotPushToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex != pushToken else { return }
        pushToken = hex
        sendJoins()
    }

    /// A kind 54 to this Mac; its answer lands in `agentReports`. Nothing while its link is down.
    func askAgents(_ macID: String, days: Int?, usage: Bool = true) {
        token += 1
        links[macID]?.send(.agentQuery, Wire.encode(AgentQuery(token: token, days: days, usage: usage)))
    }

    // MARK: Pieces

    private func startLinks() {
        guard active, let identity = DeviceIdentity.existing() else { return }
        for macID in connected where links[macID] == nil {
            guard let mac = savedMac(macID) else { continue }
            let link = BackgroundLink(macID: macID, mac: mac, identity: identity)
            link.onState = { [weak self, weak link] state in
                guard let self, let link, self.links[macID] === link else { return }
                self.states[macID] = state
                if state == .up { link.send(.linkJoin, self.joinPayload(macID)) }
            }
            link.onMessage = { [weak self, weak link] kind, payload in
                guard let self, let link, self.links[macID] === link else { return }
                self.received(kind, payload, from: macID)
            }
            links[macID] = link
            link.start()
        }
    }

    private func received(_ kind: StreamMessageKind, _ payload: Data, from macID: String) {
        switch kind {
        case .linkState:
            guard let state = Wire.decode(LinkState.self, from: payload) else { return }
            pushProblems[macID] = state.pushProblem
            #if DEBUG
            print("links: \(macID) registered \(state.registered)\(state.pushProblem.map { ", push: \($0)" } ?? "")")
            #endif
        case .agents:
            guard let report = Wire.decode(AgentReport.self, from: payload) else { return }
            agentReports[macID] = report
        case .agentEvent:
            guard let event = Wire.decode(AgentEvent.self, from: payload) else { return }
            lastFinish[macID] = event
            #if DEBUG
            print("links: \(macID): \(event.provider) finished a turn")
            #endif
        default:
            break
        }
    }

    private func sendJoins() {
        for (macID, link) in links { link.send(.linkJoin, joinPayload(macID)) }
    }

    private func joinPayload(_ macID: String) -> Data {
        token += 1
        let wants = notifies(macID) && permission != .denied
        let push = pushToken.map { PushTarget(token: $0, environment: Self.environment, topic: Bundle.main.bundleIdentifier ?? "com.gabrieldrl.sill") }
        return Wire.encode(LinkJoin(token: token, push: wants ? push : nil, features: LinkFeatures(agentsNotify: wants)))
    }

    /// A Debug build's token is APNs' sandbox's.
    private static var environment: String {
        #if DEBUG
        PushTarget.development
        #else
        PushTarget.production
        #endif
    }

    /// Each Disconnect not yet heard by its Mac: a link for the leave alone, while the app is active.
    private func sendLeaves() {
        guard active, let identity = DeviceIdentity.existing() else { return }
        for macID in leaving where leaves[macID] == nil {
            guard let mac = savedMac(macID) else { leaving.remove(macID); continue }
            let link = BackgroundLink(macID: macID, mac: mac, identity: identity)
            leaves[macID] = link
            sendLeave(link, macID)
        }
        persist()
    }

    private func sendLeave(_ link: BackgroundLink, _ macID: String) {
        link.leave { [weak self, weak link] ok in
            guard let self, let link, self.leaves[macID] === link else { return }
            self.leaves[macID] = nil
            guard ok else { return }
            self.leaving.remove(macID)
            self.persist()
            #if DEBUG
            print("links: \(macID) disconnected")
            #endif
        }
    }

    private func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard settings.authorizationStatus != self.permission else { return }
                self.permission = settings.authorizationStatus
                self.sendJoins()
            }
        }
    }

    private func savedMac(_ macID: String) -> SavedMac? {
        SavedMacs.decode(UserDefaults.standard.string(forKey: SavedMacs.defaultsKey)).first { $0.macID == macID }
    }

    private func persist() {
        UserDefaults.standard.set(connected, forKey: Self.connectedKey)
        UserDefaults.standard.set(Array(leaving).sorted(), forKey: Self.leavingKey)
    }
}
