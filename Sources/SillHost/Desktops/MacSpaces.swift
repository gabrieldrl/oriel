import Foundation
import AppKit
import CoreGraphics

/// The Mac's spaces as its window server keeps them (docs/desktops-plan.md §1): per display, its
/// desktops and full-screen apps in Mission Control's order and the one showing. Read-only: nothing
/// here switches a space; HostDesktops does that with the Mac's own shortcuts.
///
/// Private, as SymbolicHotKeys' getters are: `SLSMainConnectionID` and `SLSCopyManagedDisplaySpaces`,
/// looked up with `dlsym` in SkyLight. A macOS without them has no desktops to offer (`available`).
enum MacSpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let calls: (connection: MainConnection, copy: CopySpaces)? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let connection = dlsym(sky, "SLSMainConnectionID"),
              let copy = dlsym(sky, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(copy, to: CopySpaces.self))
    }()

    static var available: Bool { calls != nil }

    /// Every display's spaces now; nil when the calls are missing or answer nothing.
    static func read() -> [DesktopPolicy.DisplaySpaces]? {
        guard let calls, let list = calls.copy(calls.connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return DesktopPolicy.parse(list)
    }

    /// A display's UUID, as the window server names its set.
    static func uuid(_ display: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    /// A full-screen app's name, from its process.
    static func appName(_ pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
