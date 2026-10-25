import Foundation

/// The Mac's desktops (Mission Control's Spaces) on a device (kinds 53 to 55; docs/desktops-plan.md):
/// for each display, its desktops in the order macOS has them, and which one shows. A tap in the
/// device's Displays sheet switches the Mac to one; the device keeps the last picture of each.
///
/// - A host whose window list says `desktops` 1 or more lists them. A device subscribes with a kind 54
///   `{}`; the host answers with kind 53, the Mac's own display's desktops and this device's own
///   extended displays', and again whenever they change (a switch, a desktop added in Mission
///   Control, a full-screen app).
/// - `{"display":D,"id":S}` switches display D (0: the Mac's own) to space S, the way the Mac's own
///   Move left and right a space shortcuts do, one desktop at a time.
/// - Kind 55: a desktop's picture, taken while it showed, every few seconds and just after a switch.
///
/// HostSettings.swift's rules apply: JSON, every field optional and left out when nil, fields added
/// later optional; a control this host does not understand is ignored.
public struct DesktopControl: Codable, Hashable, Sendable {
    /// Which display: 0 is the Mac's own, else an `ExtendedDisplay.id`. Nil with `id` nil: the
    /// subscription.
    public var display: UInt32?
    /// The space to switch to (`MacDesktop.id`).
    public var id: UInt64?

    public init(display: UInt32? = nil, id: UInt64? = nil) {
        self.display = display; self.id = id
    }

    /// This generation (`WindowList.desktops`).
    public static let generation = 1
    /// `display` for the Mac's own display.
    public static let macDisplay: UInt32 = 0
}

/// One desktop, or a full-screen app's space.
public struct MacDesktop: Codable, Hashable, Identifiable, Sendable {
    /// The space's id, stable while the Mac runs.
    public var id: UInt64
    /// "Desktop 3", numbered among desktops only as Mission Control does; a full-screen app's name.
    public var name: String
    /// Set for a full-screen app's space: its app's name.
    public var app: String?

    public init(id: UInt64, name: String, app: String? = nil) {
        self.id = id; self.name = name; self.app = app
    }
}

/// One display's desktops.
public struct DesktopSet: Codable, Hashable, Sendable {
    /// 0: the Mac's own; else an `ExtendedDisplay.id`.
    public var display: UInt32
    /// The space showing on it; nil when macOS did not say.
    public var current: UInt64?
    public var desktops: [MacDesktop]

    public init(display: UInt32, current: UInt64?, desktops: [MacDesktop]) {
        self.display = display; self.current = current; self.desktops = desktops
    }
}

/// Host → device (kind 53).
public struct DesktopList: Codable, Hashable, Sendable {
    public var displays: [DesktopSet]

    public init(displays: [DesktopSet]) { self.displays = displays }

    /// Display `display`'s desktops, if the Mac listed them.
    public func set(_ display: UInt32) -> DesktopSet? { displays.first { $0.display == display } }
}

extension ImageBlob {
    /// Kind 55: spaceID(8, BE) + JPEG.
    public static func encodeDesktopThumbnail(spaceID: UInt64, jpeg: Data) -> Data {
        var d = Data(capacity: 8 + jpeg.count)
        d.appendBigEndian(spaceID)
        d.append(jpeg)
        return d
    }

    public static func decodeDesktopThumbnail(_ d: Data) -> (spaceID: UInt64, jpeg: Data)? {
        guard d.count > 8 else { return nil }
        return (d.readBigEndian(UInt64.self, at: 0), d.subdata(in: (d.startIndex + 8)..<d.endIndex))
    }
}
