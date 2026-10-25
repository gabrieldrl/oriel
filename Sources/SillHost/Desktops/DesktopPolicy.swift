import Foundation
import StreamProtocol

/// The Mac's desktops, decided (docs/desktops-plan.md): what the window server's list of spaces says,
/// how each is named, which display each set is, how far a switch steps, and whose a picture is.
/// Pure (Foundation only): MacSpaces reads the list, HostDesktops acts on these answers. Checked on its
/// own with swiftc (`Tests/checks/desktops`).
package enum DesktopPolicy {
    /// One space on a display, as the window server lists it.
    package struct Space: Equatable, Sendable {
        package var id: UInt64
        /// A full-screen app's space (type 4); else a desktop (type 0).
        package var fullScreen: Bool
        /// A full-screen app's process, which names it.
        package var pid: Int32?

        package init(id: UInt64, fullScreen: Bool = false, pid: Int32? = nil) {
            self.id = id; self.fullScreen = fullScreen; self.pid = pid
        }
    }

    /// One display's spaces, in Mission Control's order.
    package struct DisplaySpaces: Equatable, Sendable {
        /// The display's UUID, or "Main" when every display shares one set (Displays have separate
        /// Spaces off).
        package var uuid: String
        package var current: UInt64?
        package var spaces: [Space]

        package init(uuid: String, current: UInt64?, spaces: [Space]) {
            self.uuid = uuid; self.current = current; self.spaces = spaces
        }
    }

    /// The window server's types: a desktop, a full-screen app. Every other (the wallpaper's, a
    /// system space) is left out.
    package static let desktopType = 0
    package static let fullScreenType = 4
    /// The set macOS keeps for every display when they share their spaces.
    package static let sharedUUID = "Main"

    /// `SLSCopyManagedDisplaySpaces`'s answer: per display, "Display Identifier", "Current Space"
    /// (with "ManagedSpaceID") and "Spaces" (each with "ManagedSpaceID", "type" and, full screen,
    /// "pid"). An entry without a display or an id is left out.
    package static func parse(_ raw: [[String: Any]]) -> [DisplaySpaces] {
        raw.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String else { return nil }
            let current = ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            let spaces: [Space] = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s in
                guard let id = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                      let type = (s["type"] as? NSNumber)?.intValue,
                      type == desktopType || type == fullScreenType else { return nil }
                return Space(id: id, fullScreen: type == fullScreenType,
                             pid: type == fullScreenType ? (s["pid"] as? NSNumber)?.int32Value : nil)
            }
            return DisplaySpaces(uuid: uuid, current: current, spaces: spaces)
        }
    }

    /// Names as Mission Control gives them: "Desktop N" numbered among desktops only, a full-screen
    /// app by its app's name ("Full Screen" when it has none).
    package static func named(_ spaces: [Space], appName: (Int32) -> String?) -> [MacDesktop] {
        var n = 0
        return spaces.map { s in
            if s.fullScreen {
                let app = s.pid.flatMap(appName) ?? "Full Screen"
                return MacDesktop(id: s.id, name: app, app: app)
            }
            n += 1
            return MacDesktop(id: s.id, name: "Desktop \(n)")
        }
    }

    /// Which set is which display: the Mac's own (`DesktopControl.macDisplay`) by its UUID or the
    /// shared set's, each extended display (`displays`: its id and its UUID) by its own. A display
    /// whose UUID has no set (spaces shared) gets none.
    package static func assign(_ sets: [DisplaySpaces], mainUUID: String?,
                               displays: [(id: UInt32, uuid: String)]) -> [UInt32: DisplaySpaces] {
        var out: [UInt32: DisplaySpaces] = [:]
        if let main = sets.first(where: { $0.uuid == sharedUUID }) ?? sets.first(where: { mainUUID != nil && $0.uuid == mainUUID }) {
            out[DesktopControl.macDisplay] = main
        }
        for d in displays {
            if let s = sets.first(where: { $0.uuid == d.uuid }) { out[d.id] = s }
        }
        return out
    }

    /// A step a switch makes: Move left a space, or Move right a space.
    package enum Step: Equatable, Sendable { case left, right }

    /// At most this many steps for one switch.
    package static let maxSteps = 16
    /// How long one step may take to land before the switch gives up.
    package static let stepTimeout: Double = 1.5

    /// The steps from `current` to `target` among `spaces`: their direction and how many, or nil when
    /// there is nothing to do (already there) or nothing to go by (either is not in the list, or it is
    /// further than `maxSteps`).
    package static func steps(from current: UInt64?, to target: UInt64, in spaces: [Space]) -> (Step, Int)? {
        guard let current, current != target,
              let from = spaces.firstIndex(where: { $0.id == current }),
              let to = spaces.firstIndex(where: { $0.id == target }) else { return nil }
        let count = abs(to - from)
        guard count <= maxSteps else { return nil }
        return (to > from ? .right : .left, count)
    }

    /// Whose a picture is: the space showing just before and just after it was taken, when the same;
    /// nil across a switch (or when either is unknown).
    package static func tagged(before: UInt64?, after: UInt64?) -> UInt64? {
        guard let before, before == after else { return nil }
        return before
    }

    /// The list for a device: the Mac's own display first, then its own extended displays (`owned`,
    /// in their order), each with its desktops named.
    package static func list(_ assigned: [UInt32: DisplaySpaces], owned: [UInt32],
                             appName: (Int32) -> String?) -> DesktopList {
        let order = [DesktopControl.macDisplay] + owned
        return DesktopList(displays: order.compactMap { id in
            guard let s = assigned[id] else { return nil }
            return DesktopSet(display: id, current: s.current, desktops: named(s.spaces, appName: appName))
        })
    }
}
