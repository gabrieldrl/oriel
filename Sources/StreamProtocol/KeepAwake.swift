import Foundation

/// Extended Use: the Mac kept awake, its lid closed too, so a device can always reach it (kind 56;
/// docs/extended-use-plan.md). One setting of the Mac's, which the Mac's own pane and any device set.
///
/// - A host whose window list says `keepAwake` 1 or more offers it. A device sends `{"mode":"always"}`
///   (or "plugged", "off"); a host ignores a mode it does not know.
/// - The host sends its state after each window list and whenever it changes, to every connection:
///   the mode, whether the Mac is held awake now, whether it has a battery (When Plugged In means
///   nothing without one), whether it runs on its power adapter, and what stops it holding.
///
/// HostSettings.swift's rules apply: JSON, fields added later optional, `mode` a string so that a
/// later mode is read as unknown, never as a decoding failure.
public struct KeepAwake: Codable, Hashable, Sendable {
    public var mode: String
    /// Host → device: the Mac is held awake now.
    public var awake: Bool?
    /// Host → device: the Mac has a battery.
    public var battery: Bool?
    /// Host → device: the Mac runs on its power adapter.
    public var onPower: Bool?
    /// Host → device: why it does not hold although the mode says to; nil otherwise.
    public var problem: String?

    public init(mode: String, awake: Bool? = nil, battery: Bool? = nil, onPower: Bool? = nil, problem: String? = nil) {
        self.mode = mode; self.awake = awake; self.battery = battery; self.onPower = onPower; self.problem = problem
    }

    /// This generation (`WindowList.keepAwake`).
    public static let generation = 1
    /// `problem`: macOS waits for the user to allow Oriel's helper in Login Items.
    public static let approval = "approval"
    /// `problem`: this build cannot hold (no helper in its bundle, or signed ad hoc).
    public static let unavailable = "unavailable"
}

/// The modes this generation knows; `KeepAwake.mode` carries the raw value.
public enum KeepAwakeMode: String, CaseIterable, Sendable {
    case off
    case always
    /// When Plugged In: only while the Mac runs on its power adapter.
    case plugged
}
