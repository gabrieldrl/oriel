import Foundation
import StreamProtocol

// Extended Use: the Mac kept awake, its lid closed too (kind 56; KeepAwake.swift,
// docs/extended-use-plan.md): one setting of the Mac's, set from its Settings page here
// (MacSettingsScreen) or on the Mac. The Mac sends its state after each window list and on every
// change; this device keeps the last for each Mac, so the page shows it while the Mac is away. A
// change made while not connected to that Mac waits, and goes at its next connection.
//
// Everything here is main thread.
extension StreamClient {
    /// The Mac offers it (its window list's `keepAwake`).
    var hostHasKeepAwake: Bool { (hostKeepAwake ?? 0) >= KeepAwake.generation }

    /// Whether this session runs on `macID`'s Mac.
    func connected(to macID: String) -> Bool { connected && session?.macID == macID }

    /// Each window list's `keepAwake`: the first that says so sends a change that waited.
    func hostKeepAwakeChanged(_ value: Int?) {
        if hostKeepAwake != value { hostKeepAwake = value }
        guard hostHasKeepAwake, !keepAwakeAsked else { return }
        keepAwakeAsked = true
        guard let macID = session?.macID, let mode = Self.keepAwakePending(macID) else { return }
        Self.keepAwakeWaits(nil, macID)
        send(.keepAwake, payload: Wire.encode(KeepAwake(mode: mode.rawValue)))
    }

    /// The page's choice for `macID`'s Mac: sent now while connected to it, else kept for its next
    /// connection. The kept state shows the choice meanwhile.
    func setKeepAwake(_ mode: KeepAwakeMode, macID: String) {
        noteAction()
        var shown = keepAwakeState(macID) ?? KeepAwake(mode: mode.rawValue)
        shown.mode = mode.rawValue
        if connected(to: macID), hostHasKeepAwake {
            Self.keepAwakeWaits(nil, macID)
            keepAwake = shown
            send(.keepAwake, payload: Wire.encode(KeepAwake(mode: mode.rawValue)))
        } else {
            Self.keepAwakeWaits(mode, macID)
            keepAwakeRevision += 1
        }
    }

    /// The Mac's state: shown, and kept for this Mac.
    func receiveKeepAwake(_ state: KeepAwake) {
        if keepAwake != state { keepAwake = state }
        if let macID = session?.macID { Self.keepKeepAwake(state, macID) }
    }

    /// What the page shows for `macID`'s Mac: this session's state, else the last kept, with a change
    /// that waits for its next connection over it.
    func keepAwakeState(_ macID: String) -> KeepAwake? {
        var state = connected(to: macID) ? keepAwake ?? Self.keptKeepAwake(macID) : Self.keptKeepAwake(macID)
        if let waiting = Self.keepAwakePending(macID) {
            state = state ?? KeepAwake(mode: waiting.rawValue)
            state?.mode = waiting.rawValue
        }
        return state
    }

    /// The session ended: only what this device keeps stays.
    func resetKeepAwake() {
        hostKeepAwake = nil
        keepAwake = nil
        keepAwakeAsked = false
    }

    private static func keptKey(_ macID: String) -> String { "Sill.keepAwake.\(macID)" }
    private static func pendingKey(_ macID: String) -> String { "Sill.keepAwakePending.\(macID)" }

    static func keptKeepAwake(_ macID: String) -> KeepAwake? {
        UserDefaults.standard.data(forKey: keptKey(macID)).flatMap { Wire.decode(KeepAwake.self, from: $0) }
    }
    static func keepKeepAwake(_ state: KeepAwake, _ macID: String) {
        UserDefaults.standard.set(Wire.encode(state), forKey: keptKey(macID))
    }
    static func keepAwakePending(_ macID: String) -> KeepAwakeMode? {
        UserDefaults.standard.string(forKey: pendingKey(macID)).flatMap(KeepAwakeMode.init(rawValue:))
    }
    static func keepAwakeWaits(_ mode: KeepAwakeMode?, _ macID: String) {
        UserDefaults.standard.set(mode?.rawValue, forKey: pendingKey(macID))
    }
    static func forgetKeepAwake(_ macID: String) {
        UserDefaults.standard.removeObject(forKey: keptKey(macID))
        UserDefaults.standard.removeObject(forKey: pendingKey(macID))
    }
}
