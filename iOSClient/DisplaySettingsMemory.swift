import Foundation
// In the app StreamProtocol is its own module; the display-settings check compiles this file together
// with Sources/StreamProtocol as one module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// One display's Resolution, Frame Rate and Quality, as this device last had them on it.
struct DisplaySettings: Codable, Equatable {
    var captureScale: Double
    var maxFPS: Int
    var bitrate: Int

    init(captureScale: Double, maxFPS: Int, bitrate: Int) {
        self.captureScale = captureScale; self.maxFPS = maxFPS; self.bitrate = bitrate
    }

    init(_ s: StreamSettings) { self.init(captureScale: s.captureScale, maxFPS: s.maxFPS, bitrate: s.bitrate) }
}

/// Each display keeps its own three quick settings on this device (docs/displays-plan.md, "Settings
/// per display"): the Mac's own (Primary) and each extended display, per Mac, at home and away apart.
/// The settings stay the Mac's, one stream for every device; this is only what this device asks for
/// when it starts showing a display. Pure logic, checked on its own (Tests/checks/display-settings).
///
/// 1. The Mac's own is "Primary"; an extended display is known by its id, which the Mac makes from this
///    device and its slot, the same at every connection (its name is its place, which changes when a
///    display before it goes). A window has none: showing one changes nothing and a pick on it is kept
///    for no display.
/// 2. Away from home is kept apart from at home, as the Mac keeps an away pair.
/// 3. A display shown for the first time sends nothing and keeps what the Mac shows then, so the next
///    display's picks never carry over to it.
/// 4. A display shown again sends the fields that differ from what the Mac shows, and only values the
///    Mac offers (`SettingsChoices`: a Custom bitrate set by hand on the Mac is never asked for).
/// 5. A pick changes only its own fields in that display's memory.
enum DisplaySettingsMemory {
    static let primary = "Primary"
    static let awaySuffix = " · away"

    /// An extended display's memory at home.
    static func displayKey(_ id: UInt32) -> String { "display \(id)" }

    /// The memory `source` uses, or nil: a window, nothing, or a display the Mac has not listed yet.
    static func key(_ source: StreamSource, displays: [ExtendedDisplay], away: Bool) -> String? {
        let name: String
        switch source {
        case .desktop: name = primary
        case .display(let id):
            guard displays.contains(where: { $0.id == id }) else { return nil }
            name = displayKey(id)
        case .none, .window: return nil
        }
        return away ? name + awaySuffix : name
    }

    /// A display starts streaming with `saved` as its memory: what to send (nil: nothing), and what it
    /// remembers from now on.
    static func arriving(_ saved: DisplaySettings?, shown: StreamSettings) -> (send: HostSettingsChange?, remember: DisplaySettings) {
        guard let saved else { return (nil, DisplaySettings(shown)) }
        var change = HostSettingsChange()
        if saved.captureScale != shown.captureScale, SettingsChoices.captureScale.contains(saved.captureScale) {
            change.captureScale = saved.captureScale
        }
        if saved.maxFPS != shown.maxFPS, SettingsChoices.maxFPS.contains(saved.maxFPS) { change.maxFPS = saved.maxFPS }
        if saved.bitrate != shown.bitrate, SettingsChoices.bitrate.contains(saved.bitrate) { change.bitrate = saved.bitrate }
        return (change.isEmpty ? nil : change, saved)
    }

    /// The person picked `change` while this display streams: its memory from now on.
    static func recording(_ change: HostSettingsChange, into saved: DisplaySettings?, shown: StreamSettings) -> DisplaySettings {
        var s = saved ?? DisplaySettings(shown)
        if let v = change.captureScale { s.captureScale = v }
        if let v = change.maxFPS { s.maxFPS = v }
        if let v = change.bitrate { s.bitrate = v }
        return s
    }
}
