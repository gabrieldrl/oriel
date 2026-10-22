import Foundation
import CoreGraphics

/// What the curtain stops (kind 52; docs/curtain-plan.md): pure, so it is checked on its own
/// (Tests/checks/curtain).
///
/// 1. Every event Sill posts for a device carries `marker` in its source user data (InputInjector's
///    one `post`), and always goes through.
/// 2. Anything else of the Mac's own keyboard, trackpad, mouse, tablet and its system keys
///    (brightness, volume, media: `systemDefined`) is dropped while the curtain is up.
/// 3. Every other event goes through as it is: the tap's own notes, and kinds it does not know.
enum CurtainPolicy {
    /// In `kCGEventSourceUserData` of every event Sill posts: "Sill" and "C0DE".
    static let marker: Int64 = 0x5111_C0DE

    /// CGEventType raw values: the pointer's buttons and moves, keys, scrolls, the tablet, the system
    /// keys (14, NSEvent's systemDefined), and the trackpad's gestures (NSEvent's 18 to 20 and 29 to 34,
    /// which CGEventType does not name).
    static let blocked: Set<UInt32> = [
        1, 2, 3, 4, 5, 6, 7,          // left and right down and up, moved, dragged
        10, 11, 12,                   // key down, key up, modifiers
        14,                           // system keys: brightness, volume, media, eject
        18, 19, 20,                   // rotate, begin and end gesture
        22, 23, 24,                   // scroll wheel, tablet pointer and proximity
        25, 26, 27,                   // other mouse down, up, dragged
        29, 30, 31, 32, 33, 34,       // gesture, magnify, swipe, smart magnify, quick look, pressure
    ]

    /// Whether an event of `type` with `userData` is dropped while the curtain is up.
    static func blocks(type: UInt32, userData: Int64) -> Bool {
        userData != marker && blocked.contains(type)
    }

    /// The tap's mask: every blocked type.
    static var mask: CGEventMask {
        blocked.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }
}
