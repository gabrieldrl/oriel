import Foundation

/// The Mac's screen off while a device works it (kind 52; docs/curtain-plan.md): the Mac's own
/// displays go dark (its built-in display's brightness to 0, and black over every display it has),
/// and its own keyboard, trackpad and mouse do nothing, while the device sees and works it as before.
///
/// - A host whose window list says `curtain` 1 or more offers it. A device sends `{"on":true}` or
///   `{"on":false}`; the host answers each with this device's state: `on` while the curtain is up for
///   it, and `problem` when it could not be put up ("accessibility": Sill is not allowed to control
///   the Mac, which blocking its own input needs).
/// - It is up while any connected device wants it, and goes the moment none does: a Disconnect, a
///   lost connection, Sill quitting. A device never leaves the Mac dark and locked behind it.
///
/// HostSettings.swift's rules apply: JSON, fields added later optional.
public struct CurtainControl: Codable, Hashable, Sendable {
    public var on: Bool
    /// Host → device: why it is not up although asked; nil otherwise.
    public var problem: String?

    public init(on: Bool, problem: String? = nil) {
        self.on = on; self.problem = problem
    }

    /// This generation (`WindowList.curtain`).
    public static let generation = 1
    /// `problem`: blocking the Mac's own input needs Accessibility.
    public static let accessibility = "accessibility"
}
