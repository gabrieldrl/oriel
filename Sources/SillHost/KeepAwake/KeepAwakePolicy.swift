import Foundation
import StreamProtocol

/// Extended Use's rules (kind 56; docs/extended-use-plan.md): pure, so they are checked on their own
/// (Tests/checks/keep-awake). HostKeepAwake does what they say.
///
/// 1. Off never holds, Always always does, When Plugged In only while the Mac runs on its adapter.
/// 2. The helper (SillAwake, the launch daemon that can stop the lid's sleep) is registered the first
///    time a mode other than Off is chosen, and stays registered: it holds nothing while Off, and
///    unregistering would make macOS ask again next time.
/// 3. The Mac is held only while the helper is enabled; until then the state says why not.
package enum KeepAwakePolicy {
    /// What macOS says of the helper's registration (SMAppService.Status), or that this build
    /// cannot have one (no helper in its bundle, a register that failed: signed ad hoc).
    package enum Helper: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unavailable
    }

    /// A device's or the pane's mode: nil for one this generation does not know, which is ignored.
    package static func mode(_ raw: String) -> KeepAwakeMode? { KeepAwakeMode(rawValue: raw) }

    /// Whether the mode wants the Mac held awake now.
    package static func wants(_ mode: KeepAwakeMode, onPower: Bool) -> Bool {
        switch mode {
        case .off: return false
        case .always: return true
        case .plugged: return onPower
        }
    }

    /// Whether to register the helper now.
    package static func register(_ mode: KeepAwakeMode, helper: Helper) -> Bool {
        mode != .off && (helper == .notRegistered || helper == .notFound)
    }

    /// Whether to ask the helper to hold.
    package static func hold(_ mode: KeepAwakeMode, onPower: Bool, helper: Helper) -> Bool {
        wants(mode, onPower: onPower) && helper == .enabled
    }

    /// Why the Mac is not held although the mode wants it: nil while it is, or while nothing is wanted.
    /// A helper not yet registered waits for the same approval a registered one does.
    package static func problem(_ mode: KeepAwakeMode, onPower: Bool, helper: Helper) -> String? {
        guard wants(mode, onPower: onPower) else { return nil }
        switch helper {
        case .enabled: return nil
        case .requiresApproval, .notRegistered, .notFound: return KeepAwake.approval
        case .unavailable: return KeepAwake.unavailable
        }
    }

    /// The state every connection is sent. `held`: what the helper last answered.
    package static func state(_ mode: KeepAwakeMode, held: Bool, battery: Bool, onPower: Bool, helper: Helper) -> KeepAwake {
        KeepAwake(mode: mode.rawValue, awake: held && hold(mode, onPower: onPower, helper: helper), battery: battery,
                  onPower: onPower, problem: problem(mode, onPower: onPower, helper: helper))
    }

    /// Whether Always carries its one line, "Increases heat and battery use.": only on a Mac with a battery.
    package static func warns(_ mode: KeepAwakeMode, battery: Bool) -> Bool { mode == .always && battery }

    /// The modes offered: When Plugged In only on a Mac with a battery.
    package static func offered(battery: Bool) -> [KeepAwakeMode] { battery ? [.off, .always, .plugged] : [.off, .always] }
}
