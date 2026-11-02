import Foundation
import CoreGraphics

/// What the curtain stops, and how dark it makes the built-in display (kind 52;
/// docs/curtain-plan.md): pure, so it is checked on its own (Tests/checks/curtain).
///
/// 1. Every event Sill posts for a device carries `marker` in its source user data (InputInjector's
///    one `post`), and always goes through.
/// 2. Anything else of the Mac's own keyboard, trackpad, mouse, tablet and its system keys
///    (brightness, volume, media: `systemDefined`) is dropped while the curtain is up.
/// 3. Every other event goes through as it is: the tap's own notes, and kinds it does not know.
/// 4. The built-in display goes down to `builtInBrightness`, or stays at its own level when that is
///    lower; never 0, which turns its backlight off and hides the mark the external displays show.
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

    /// The built-in display's brightness while the curtain is up (DisplayServices' 0 to 1): dark from
    /// across a room, bright enough for the mark (Gabriel, 2026-11-02: at 0 only the externals had it).
    static let builtInBrightness: Float = 0.25

    /// The level the built-in display is held at, from the level it had (nil: it could not be read).
    static func dimmed(from level: Float?) -> Float {
        min(level ?? builtInBrightness, builtInBrightness)
    }
}
