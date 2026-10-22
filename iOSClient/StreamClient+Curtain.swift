import Foundation
import StreamProtocol

// The Mac's screen off and its own input away while this device works it (kind 52; Curtain.swift,
// docs/curtain-plan.md): the eye pill (QuickControls' CurtainControl). Off at first; this device keeps
// the last choice for each Mac and asks for it again at that Mac's next connection, and on a move's
// new connection. The Mac lifts it the moment this device is gone.
//
// Everything here is main thread.
extension StreamClient {
    /// The Mac offers it (its window list's `curtain`).
    var hostHasCurtain: Bool { (hostCurtain ?? 0) >= CurtainControl.generation }

    /// Each window list's `curtain`: the first that says so asks for this Mac's kept choice.
    func hostCurtainChanged(_ value: Int?) {
        if hostCurtain != value { hostCurtain = value }
        guard hostHasCurtain, !curtainAsked else { return }
        curtainAsked = true
        guard let macID = session?.macID, Self.curtainKept(macID) else { return }
        send(.curtain, payload: Wire.encode(CurtainControl(on: true)))
    }

    /// The pill's tap: on or off, kept for this Mac.
    func setCurtain(_ on: Bool) {
        guard hostHasCurtain else { return }
        noteAction()
        if let macID = session?.macID { Self.keepCurtain(on, macID) }
        curtainOn = on
        curtainProblem = nil
        send(.curtain, payload: Wire.encode(CurtainControl(on: on)))
    }

    /// The Mac's answer: up for this device or not, and why not.
    func receiveCurtain(_ state: CurtainControl) {
        if curtainOn != state.on { curtainOn = state.on }
        if curtainProblem != state.problem { curtainProblem = state.problem }
    }

    /// A move handed the session to its new connection: the Mac keeps what each connection wants.
    func curtainMoved() {
        curtainAsked = false
        hostCurtainChanged(hostCurtain)
    }

    /// The session ended: only the kept choice stays.
    func resetCurtain() {
        hostCurtain = nil
        curtainOn = false
        curtainProblem = nil
        curtainAsked = false
    }

    private static func curtainKey(_ macID: String) -> String { "Sill.curtain.\(macID)" }
    static func curtainKept(_ macID: String) -> Bool { UserDefaults.standard.bool(forKey: curtainKey(macID)) }
    static func keepCurtain(_ on: Bool, _ macID: String) { UserDefaults.standard.set(on, forKey: curtainKey(macID)) }
}
