import Foundation
import IOKit.ps
import Network
import Observation
import ServiceManagement
import SillAwakeXPC
import StreamProtocol

/// Extended Use: the Mac kept awake, its lid closed too, so a device can always reach it (kind 56,
/// KeepAwake.swift; docs/extended-use-plan.md). One setting of the Mac's, Off by default, which the
/// pane (Settings › General) and any device set; KeepAwakePolicy decides, this does it:
/// - the mode, kept in `Sill.keepAwake`;
/// - the power source, followed while the app runs (When Plugged In holds only on the adapter);
/// - SillAwake, the launch daemon that can stop the lid's sleep: registered with SMAppService the first
///   time a mode other than Off is chosen, allowed by the user once in Login Items, then asked over XPC
///   to hold or let go. It lets go by itself when this app's connection goes, so a quit or a crash
///   never leaves the Mac unable to sleep;
/// - the state, to every connection after its window list and on every change.
///
/// Available only to Oriel.app, whose bundle carries the daemon. A synthetic host keeps the state and
/// touches nothing on this Mac: no defaults, no daemon, no power source (a laptop on its adapter).
/// Main actor, as the coordinator is; the pane observes it.
@MainActor @Observable
package final class HostKeepAwake {
    /// The window lists' `keepAwake`: nil when this host cannot.
    var advertised: Int? { available ? KeepAwake.generation : nil }
    package let available: Bool
    package private(set) var mode: KeepAwakeMode = .off
    package private(set) var battery = true
    package private(set) var onPower = true
    package private(set) var helper: KeepAwakePolicy.Helper = .notRegistered
    /// What the daemon last answered: sleep is disabled now.
    package private(set) var held = false

    package var problem: String? { KeepAwakePolicy.problem(mode, onPower: onPower, helper: helper) }
    package var offered: [KeepAwakeMode] { KeepAwakePolicy.offered(battery: battery) }
    package var warns: Bool { KeepAwakePolicy.warns(mode, battery: battery) }
    /// Held now, as the devices are told.
    package var awake: Bool { state.awake == true }

    /// Whether this app's bundle carries the daemon (Scripts/make-app.sh): the bare binary has none.
    package static var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(SillAwakeService.plist)").path)
    }

    @ObservationIgnored private let server: StreamServer
    @ObservationIgnored private let synthetic: Bool
    @ObservationIgnored private var connection: NSXPCConnection?
    /// The hold last asked of the daemon, so a change of nothing asks nothing.
    @ObservationIgnored private var asked: Bool?
    @ObservationIgnored private var lastSent: KeepAwake?
    @ObservationIgnored private var power: CFRunLoopSource?
    @ObservationIgnored private let powerBox = PowerBox()
    /// While macOS waits for the user's approval: its status read again every few seconds.
    @ObservationIgnored private var approvalCheck: Timer?
    @ObservationIgnored private var retry: Timer?

    private static let key = "Sill.keepAwake"

    init(server: StreamServer, synthetic: Bool, available: Bool) {
        self.server = server
        self.synthetic = synthetic
        self.available = available
        guard available else { return }
        if synthetic {
            helper = .enabled
            return
        }
        mode = UserDefaults.standard.string(forKey: Self.key).flatMap(KeepAwakePolicy.mode) ?? .off
        readPower()
        watchPower()
        readHelper()
        apply()
    }

    // MARK: From the pane and the devices

    /// The pane's choice (`who` nil) or a device's.
    package func set(_ new: KeepAwakeMode, who: String?) {
        guard available, new != mode else { return }
        mode = new
        if !synthetic { UserDefaults.standard.set(new.rawValue, forKey: Self.key) }
        print("Extended Use: \(Self.word(new)), from \(who ?? "this Mac's Settings").")
        apply()
    }

    /// A kind 56 from `connection`, named `who`: a mode this generation knows, else nothing. One this
    /// Mac does not offer (When Plugged In without a battery, from a device that did not know) is
    /// answered with the state as it is.
    func received(_ payload: Data, from connection: NWConnection, who: String) {
        guard available, let asked = Wire.decode(KeepAwake.self, from: payload),
              let new = KeepAwakePolicy.mode(asked.mode) else { return }
        if new == mode || !offered.contains(new) { sendState(to: connection) } else { set(new, who: who) }
    }

    /// After `connection`'s window list.
    func sendState(to connection: NWConnection) {
        guard available else { return }
        server.send(message(state), to: connection)
    }

    /// The daemon's registration read again: the pane, once a second while it shows.
    package func refresh() {
        guard available, !synthetic else { return }
        let before = helper
        readHelper()
        if helper != before { apply() }
    }

    package func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Oriel is quitting: let go now (the daemon would when the connection closes anyway).
    func shutdown() {
        guard available, !synthetic, asked == true else { return }
        connection?.invalidate()
        connection = nil
        asked = nil
        held = false
    }

    // MARK: Doing it

    private var state: KeepAwake {
        KeepAwakePolicy.state(mode, held: synthetic ? true : held, battery: battery, onPower: onPower, helper: helper)
    }

    /// The registration, the hold and the state, as the policy says for what is true now.
    private func apply() {
        if !synthetic {
            if KeepAwakePolicy.register(mode, helper: helper) { registerHelper() }
            let hold = KeepAwakePolicy.hold(mode, onPower: onPower, helper: helper)
            // Nothing asked yet is nothing held: a Mac left Off never talks to the daemon.
            if hold != (asked ?? false) { ask(hold) }
            watchApproval(helper == .requiresApproval && mode != .off)
        }
        publish()
    }

    /// Every connection hears a state that changed.
    private func publish() {
        let now = state
        guard now != lastSent else { return }
        lastSent = now
        server.broadcast(message(now))
    }

    private func message(_ state: KeepAwake) -> StreamMessage {
        StreamMessage(kind: .keepAwake, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: Wire.encode(state))
    }

    private func registerHelper() {
        do {
            try SMAppService.daemon(plistName: SillAwakeService.plist).register()
            print("Extended Use: Oriel's helper registered; macOS asks for it in Login Items.")
        } catch {
            print("Extended Use: Oriel's helper could not be registered: \(error.localizedDescription)")
        }
        readHelper(afterRegister: true)
    }

    /// `afterRegister`: a helper still not registered after a register can't be (signed ad hoc, say).
    private func readHelper(afterRegister: Bool = false) {
        switch SMAppService.daemon(plistName: SillAwakeService.plist).status {
        case .enabled: helper = .enabled
        case .requiresApproval: helper = .requiresApproval
        case .notFound: helper = afterRegister ? .unavailable : .notFound
        case .notRegistered: helper = afterRegister ? .unavailable : (helper == .unavailable ? .unavailable : .notRegistered)
        @unknown default: helper = .unavailable
        }
    }

    private func watchApproval(_ on: Bool) {
        if on, approvalCheck == nil {
            approvalCheck = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else if !on {
            approvalCheck?.invalidate()
            approvalCheck = nil
        }
    }

    /// Asks the daemon to hold or let go; its answer becomes `held`.
    private func ask(_ hold: Bool) {
        asked = hold
        retry?.invalidate()
        retry = nil
        guard let daemon = daemon() else { return }
        daemon.hold(hold) { [weak self] disabled, error in
            Task { @MainActor in
                guard let self, self.asked == hold else { return }
                if let error { print("Extended Use: \(error)") }
                if self.held != disabled {
                    self.held = disabled
                    print(disabled ? "Extended Use: this Mac stays awake, its lid closed too." : "Extended Use: this Mac sleeps as it would.")
                }
                self.publish()
            }
        }
    }

    private func daemon() -> SillAwakeXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: SillAwakeService.name, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: SillAwakeXPC.self)
            c.setCodeSigningRequirement(SillAwakeService.helperRequirement)
            // The daemon gone (it crashed, or launchd stopped it): ask again in a moment.
            let lost: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.daemonLost() } }
            c.interruptionHandler = lost
            c.invalidationHandler = lost
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            print("Extended Use: Oriel's helper did not answer: \(error.localizedDescription)")
        } as? SillAwakeXPC
    }

    private func daemonLost() {
        connection = nil
        let wanted = asked
        asked = nil
        if held { held = false; publish() }
        guard wanted == true, retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retry = nil
                self?.apply()
            }
        }
    }

    // MARK: The power source

    private func readPower() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        onPower = providing != kIOPMBatteryPowerKey
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        battery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    private func watchPower() {
        powerBox.changed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let before = (self.onPower, self.battery)
                self.readPower()
                guard before != (self.onPower, self.battery) else { return }
                print("Extended Use: \(self.onPower ? "on the power adapter" : "on battery").")
                self.apply()
            }
        }
        let context = Unmanaged.passUnretained(powerBox).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerBox>.fromOpaque(context).takeUnretainedValue().changed?()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        power = source
    }

    package static func word(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: return "Off"
        case .always: return "Always"
        case .plugged: return "When Plugged In"
        }
    }
}

/// The power source callback's way back, held for as long as the source lives.
private final class PowerBox {
    var changed: (() -> Void)?
}
