import Foundation

/// The Mac's extended displays on a device (kinds 49 to 51; docs/displays-plan.md). Each is a display
/// to macOS, made by Sill.app for one device (CGVirtualDisplay): it sits in System Settings › Displays
/// where the person puts it, windows go onto it, the pointer crosses to it. A device streams one
/// display at a time, its own or the Mac's (`StreamSource.desktop`), or a window, as before.
///
/// - A host whose window list says `displays` 1 or more makes them. A device subscribes with any kind
///   50 (`{}` at connect), which brings back the displays it had when it last left, each where macOS
///   remembers it and with its windows; the host answers with kind 49, this device's displays, and
///   again after every change.
/// - `add` makes one more at `width`×`height` points (the room the device shows it in), up to `max`;
///   `remove` takes one away for good (its windows go to the Mac's own display); `end` is Disconnect:
///   this device's displays go now, to come back at its next connection. A connection that is lost
///   keeps them `DisplayList.grace` seconds, so a reconnect finds them as they were.
/// - `resize` makes one again at a new size, where macOS has it and with its windows: `match`
///   "primary" for the Mac's own display's size in points (kept as such: brought back later at that
///   display's size then), else `width`×`height` (the room the device shows it in, its default).
///   A display streaming goes on streaming at its new size.
/// - Streaming one is a pick: kind 6 with `StreamSource.display(id)`.
///
/// HostSettings.swift's rules apply: JSON, every field optional and left out when nil, fields added
/// later optional; an action this host does not know is ignored.
public struct DisplayControl: Codable, Hashable, Sendable {
    /// Nil: the subscription. "add", "remove", "resize", "end".
    public var action: String?
    /// `remove`, `resize`: which.
    public var id: UInt32?
    /// `add`, `resize`: the display's size in points (HiDPI, two pixels a point).
    public var width: Int?
    public var height: Int?
    /// `resize`: "primary", the Mac's own display's size, in place of `width` and `height`.
    public var match: String?

    public init(action: String? = nil, id: UInt32? = nil, width: Int? = nil, height: Int? = nil, match: String? = nil) {
        self.action = action; self.id = id; self.width = width; self.height = height; self.match = match
    }

    public static let add = "add"
    public static let remove = "remove"
    public static let resize = "resize"
    public static let end = "end"
    /// `match`'s one value.
    public static let primary = "primary"

    /// This generation (`WindowList.displays`).
    public static let generation = 1
}

/// One extended display.
public struct ExtendedDisplay: Codable, Hashable, Identifiable, Sendable {
    /// Stable for this device and slot across sessions (the display's serial number, by which macOS
    /// remembers where it goes).
    public var id: UInt32
    /// "Display 2": the Mac's own is 1.
    public var name: String
    /// Points.
    public var width: Int
    public var height: Int
    /// True: sized as the Mac's own display (`DisplayControl.primary`); nil: the size the device asked.
    public var matchesPrimary: Bool?

    public init(id: UInt32, name: String, width: Int, height: Int, matchesPrimary: Bool? = nil) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.matchesPrimary = matchesPrimary
    }
}

/// Host → device (kind 49): this device's extended displays.
public struct DisplayList: Codable, Hashable, Sendable {
    public var displays: [ExtendedDisplay]
    /// How many this device may have.
    public var max: Int
    /// Why the last `add` made nothing ("limit", "failed"); nil otherwise.
    public var problem: String?

    public init(displays: [ExtendedDisplay], max: Int, problem: String? = nil) {
        self.displays = displays; self.max = max; self.problem = problem
    }

    /// Seconds a lost connection's displays stay for its reconnect.
    public static let grace: Double = 30
}
