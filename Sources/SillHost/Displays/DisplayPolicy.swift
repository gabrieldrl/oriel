import Foundation
import CoreGraphics
import StreamProtocol

/// The extended displays' rules (docs/displays-plan.md), pure: Tests/checks/displays. ExtendedDisplays
/// does what they say.
enum DisplayPolicy {
    /// How many displays one device may have, besides the Mac's own.
    static let maxPerDevice = 4

    /// The identity macOS remembers a display by (where it goes, its mode): Sill's vendor, which
    /// `StreamCoordinator.isSillVirtualDisplay` and the app's windows know (VirtualStage's), and a
    /// product of their own, so a window's stage and an extended display never share an entry in
    /// System Settings › Displays.
    static let vendorID: UInt32 = 0x5111
    static let productID: UInt32 = 0x0002

    /// A display's id and serial number: 24 bits of its device (FNV-1a of the owner's key), then its
    /// slot. The same device and slot give the same number every session, on every launch, so macOS
    /// puts the display back where it was. Never 0.
    static func serial(owner: String, slot: Int) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in owner.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        let device = (hash >> 8) == 0 ? 1 : hash >> 8
        return device << 8 | UInt32(slot & 0xFF)
    }

    /// The slot in a display's id.
    static func slot(of id: UInt32) -> Int { Int(id & 0xFF) }

    /// A device's display named by its place among that device's displays (`slots`), in slot order:
    /// "Display 2" for the first, the Mac's own being the first. A gap a removed display leaves closes.
    static func name(slot: Int, among slots: [Int]) -> String {
        "Display \(Set(slots).filter { $0 < slot }.count + 2)"
    }

    /// The first free slot, 1 on; nil at `maxPerDevice`.
    static func nextSlot(used: Set<Int>) -> Int? {
        (1...maxPerDevice).first { !used.contains($0) }
    }

    /// A display's owner: its device's key (hex), else, on a door that sees no key (the CLI's plain
    /// door, a test host), its name.
    static func owner(fingerprint: Data?, name: String) -> String {
        if let fingerprint, !fingerprint.isEmpty { return fingerprint.map { String(format: "%02x", $0) }.joined() }
        return "name:" + name
    }

    /// Before a device says how much room it has: an iPad Pro 13-inch's points.
    static let defaultSize = (width: 1366, height: 1024)
    /// Each side, in points.
    static let sides = 640...3840

    /// The size a device asked for, each side kept within `sides` and even; nil or nothing usable:
    /// `defaultSize`.
    static func size(width: Int?, height: Int?) -> (width: Int, height: Int) {
        guard let width, let height, width > 0, height > 0 else { return defaultSize }
        func side(_ v: Int) -> Int { min(max(v, sides.lowerBound), sides.upperBound) & ~1 }
        return (side(width), side(height))
    }

    /// The Mac's own display as a display is matched to it: its size in points and its pixels a point.
    struct Primary: Equatable {
        var width: CGFloat
        var height: CGFloat
        var pixelWidth: Int

        /// 1 or 2: a display at its full resolution (as many points as pixels) is 1.
        var scale: Int { width > 0 && CGFloat(pixelWidth) / width >= 1.5 ? 2 : 1 }
    }

    /// Slot `slot` as a `resize` makes it: as the Mac's own display (`primary`) for `match` "primary",
    /// its size and scale, kept as matching it; else at the size the device asked, clamped as an add's,
    /// at 2×.
    static func resized(_ control: DisplayControl, slot: Int, primary: Primary) -> Memory.Slot {
        if control.match == DisplayControl.primary { return matching(slot: slot, primary) }
        let s = size(width: control.width, height: control.height)
        return Memory.Slot(slot: slot, width: s.width, height: s.height)
    }

    /// A remembered slot as it is made again: one matching the Mac's own display at that display's
    /// size and scale now, which may have changed since.
    static func bringingBack(_ slot: Memory.Slot, primary: Primary) -> Memory.Slot {
        slot.matchesPrimary == true ? matching(slot: slot.slot, primary) : slot
    }

    private static func matching(slot: Int, _ primary: Primary) -> Memory.Slot {
        let s = size(width: Int(primary.width.rounded()), height: Int(primary.height.rounded()))
        return Memory.Slot(slot: slot, width: s.width, height: s.height, matchesPrimary: true,
                           scale: primary.scale == 2 ? nil : primary.scale)
    }

    /// How a device's displays end when it goes.
    enum Ending: Equatable {
        /// Disconnect (`DisplayControl.end`): now, to come back at its next connection.
        case disconnect
        /// The connection was lost: after `DisplayList.grace`, unless it is back.
        case lost
        /// `DisplayControl.remove`: now, and for good.
        case removed
    }

    /// Seconds until the display goes.
    static func keepFor(_ ending: Ending) -> Double {
        ending == .lost ? DisplayList.grace : 0
    }

    /// Its windows are kept to come back with it: not for a display removed for good.
    static func keepsWindows(_ ending: Ending) -> Bool { ending != .removed }

    // MARK: Windows

    /// A window on a display as it went, to be put back when it comes back.
    struct Kept: Codable, Equatable {
        var slot: Int
        var windowID: UInt32
        var pid: Int32
        var app: String
        var title: String
        /// Its top-left corner from the display's, and its size, in points.
        var offset: CGPoint
        var size: CGSize
        /// Where macOS put it once the display had gone; nil when that was not seen (Sill quit).
        var fellTo: CGRect?
    }

    /// A window counts as on a display when its centre is.
    static func isOn(_ window: CGRect, display: CGRect) -> Bool {
        display.contains(CGPoint(x: window.midX, y: window.midY))
    }

    /// Points either way that still count as the same place.
    static let tolerance: CGFloat = 2

    /// A kept window goes back when it is still open (`now`) and nobody moved it from where macOS put
    /// it: a window moved on the Mac meanwhile stays where it was put, as a display's own do.
    static func returns(_ k: Kept, now: CGRect?) -> Bool {
        guard let now else { return false }
        guard let fell = k.fellTo else { return true }
        return abs(now.minX - fell.minX) <= tolerance && abs(now.minY - fell.minY) <= tolerance
            && abs(now.width - fell.width) <= tolerance && abs(now.height - fell.height) <= tolerance
    }

    /// Where a kept window's corner goes on its display's `bounds` now: the same place from its
    /// corner, kept on it with at least `visible` points of the window inside (a display that came
    /// back smaller).
    static func placed(_ k: Kept, on bounds: CGRect, visible: CGFloat = 100) -> CGPoint {
        let x = bounds.minX + k.offset.x, y = bounds.minY + k.offset.y
        let reachX = min(visible, k.size.width), reachY = min(visible, k.size.height)
        return CGPoint(x: min(max(x, bounds.minX - k.size.width + reachX), bounds.maxX - reachX),
                       y: min(max(y, bounds.minY), bounds.maxY - reachY))
    }

    // MARK: What is remembered

    /// Each device's displays and their windows, kept across connections and launches.
    struct Memory: Codable, Equatable {
        struct Slot: Codable, Equatable {
            var slot: Int
            var width: Int
            var height: Int
            /// Sized as the Mac's own display: made again at that display's size then.
            var matchesPrimary: Bool?
            /// Pixels a point; nil is 2 (HiDPI). A display matching the Mac's own has its scale.
            var scale: Int?
        }
        struct Owner: Codable, Equatable {
            var slots: [Slot] = []
            var windows: [Kept] = []
        }
        var owners: [String: Owner] = [:]
    }
}

extension StreamSource {
    /// The Desktop or an extended display: the frontmost app's menus, the whole screen's input.
    var isDesktop: Bool {
        switch self {
        case .desktop, .display: return true
        case .none, .window: return false
        }
    }

    /// How a window list says it: an extended display is the Desktop with `showing`, which an older
    /// device reads as the Desktop (Switcher.swift).
    var listed: (active: StreamSource, showing: UInt32?) {
        if case .display(let id) = self { return (.desktop, id) }
        return (self, nil)
    }
}
