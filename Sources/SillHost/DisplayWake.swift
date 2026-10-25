import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// The Mac's display awake for a stream. Measured 2026-10-25: with the display asleep a device's
/// pick streamed nothing, with no line in the log ("nothing captured", the device's picture black),
/// and the Mac's Move left a space did not move it either. So a pick wakes it first, as a touch of
/// the keyboard would (`wake`), and while anything streams it does not idle to sleep (`hold`): a
/// device only watching sends no input, and the display would sleep under it. The display's own
/// sleep on the Mac (closing the lid, the menu's Sleep) still wins. A synthetic host never comes
/// here: it touches nothing on this Mac. Main actor, as the coordinator is.
@MainActor
final class DisplayWake {
    private var held: IOPMAssertionID?

    /// The Mac's own display sleeps now.
    static var asleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Wakes the display and waits up to `timeout` for it; true when it is awake.
    func wake(timeout: Duration = .seconds(3)) async -> Bool {
        guard Self.asleep else { return true }
        var id: IOPMAssertionID = 0
        let declared = IOPMAssertionDeclareUserActivity("Oriel: a device asked for this Mac's screen" as CFString,
                                                        kIOPMUserActiveLocal, &id)
        defer { if declared == kIOReturnSuccess { IOPMAssertionRelease(id) } }
        let deadline = ContinuousClock.now + timeout
        while Self.asleep, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return !Self.asleep
    }

    /// Keeps the display from idling to sleep while `on` (something streams).
    func hold(_ on: Bool) {
        if on, held == nil {
            var id: IOPMAssertionID = 0
            guard IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                              "Oriel is streaming this Mac's screen" as CFString, &id) == kIOReturnSuccess else { return }
            held = id
        } else if !on, let id = held {
            IOPMAssertionRelease(id)
            held = nil
        }
    }
}
