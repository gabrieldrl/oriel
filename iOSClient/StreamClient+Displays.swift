import UIKit
import Network
import StreamProtocol

// The Mac's extended displays, this device's side (kinds 49 to 51; docs/displays-plan.md). Each is a
// display to macOS that Sill.app makes for this device: arranged in System Settings › Displays,
// windows dragged onto it, the pointer crossing to it. This device streams one at a time, or the Mac's
// own, or a window, from the Displays sheet (DisplaysTray).
//
// - The subscription: an empty kind 50 at the first window list that says `displays`, again on a
//   move's new connection. It brings back the displays this device had on that Mac when it last left,
//   each where macOS remembers it, with its windows; the connection's first pick is the one this device
//   last watched there (`firstSource`).
// - Disconnect is from the whole Mac: `end` goes just before the connection closes, and the displays
//   go with it, to come back next time. A connection that is lost keeps them 30 s on the Mac.
// - Each display keeps its own Resolution, Frame Rate and Quality on this device (DisplaySettingsMemory),
//   asked of the Mac whenever this device starts showing it.
//
// Everything here is main thread.
extension StreamClient {
    /// The Mac makes extended displays (its window list's `displays`).
    var hostMakesDisplays: Bool { (hostDisplays ?? 0) >= DisplayControl.generation }

    /// Each window list's `displays`: the first that says so subscribes.
    func hostDisplaysChanged(_ value: Int?) {
        if hostDisplays != value { hostDisplays = value }
        guard hostMakesDisplays, !displaysSubscribed else { return }
        displaysSubscribed = true
        send(.displayControl, payload: Wire.encode(DisplayControl()))
        #if DEBUG
        print("displays: subscribed")
        #endif
    }

    /// A move handed the session to its new connection: the Mac keeps subscriptions per connection.
    func displaysMoved() {
        displaysSubscribed = false
        hostDisplaysChanged(hostDisplays)
    }

    /// The session ended: nothing of it is kept but which display this device last watched, and each
    /// display's settings.
    func resetDisplays() {
        hostDisplays = nil
        displaysSubscribed = false
        extendedDisplays = []
        displaysMax = 0
        displaysProblem = nil
        displayPictures = [:]
        pendingNewDisplay = nil
        displaySettingsArriving = nil
    }

    /// A kind 49 from the Mac.
    func receiveDisplays(_ list: DisplayList) {
        if extendedDisplays != list.displays { extendedDisplays = list.displays }
        if displaysMax != list.max { displaysMax = list.max }
        if displaysProblem != list.problem { displaysProblem = list.problem }
        let live = Set(list.displays.map(\.id))
        displayPictures = displayPictures.filter { $0.key == 0 || live.contains($0.key) }
        applyDisplaySettings()
    }

    /// Whether another display can be made.
    var canAddDisplay: Bool { hostMakesDisplays && extendedDisplays.count < displaysMax }

    /// A new display at `size` (the room this device shows it in, points), streamed as soon as the
    /// Mac lists it.
    func addDisplay(size: CGSize) {
        guard canAddDisplay else { return }
        let before = Set(extendedDisplays.map(\.id))
        noteAction()
        send(.displayControl, payload: Wire.encode(DisplayControl(action: DisplayControl.add,
                                                                  width: Int(size.width.rounded()), height: Int(size.height.rounded()))))
        pendingNewDisplay = before
    }

    /// Takes display `id` away for good; its windows go to the Mac's own display.
    func removeDisplay(_ id: UInt32) {
        noteAction()
        if let macID = session?.macID {
            if Self.lastDisplay(macID) == id { Self.setLastDisplay(nil, macID) }
            // Its settings go with it: the next display in its slot starts afresh.
            var all = Self.displaySettings(macID)
            let key = DisplaySettingsMemory.displayKey(id)
            if all[key] != nil || all[key + DisplaySettingsMemory.awaySuffix] != nil {
                all[key] = nil
                all[key + DisplaySettingsMemory.awaySuffix] = nil
                Self.setDisplaySettings(all, macID)
            }
        }
        // The Mac streams its own display in place of this one: Primary's settings come back.
        if active == .display(id) { displaySettingsArriving = .desktop }
        send(.displayControl, payload: Wire.encode(DisplayControl(action: DisplayControl.remove, id: id)))
    }

    /// Display `id` made again as the Mac's own display (its size and scale), or at `room` (this
    /// screen's, the size a new one gets). It keeps streaming at its new size.
    func resizeDisplay(_ id: UInt32, matchingPrimary: Bool, room: CGSize) {
        noteAction()
        let control = matchingPrimary
            ? DisplayControl(action: DisplayControl.resize, id: id, match: DisplayControl.primary)
            : DisplayControl(action: DisplayControl.resize, id: id, width: Int(room.width.rounded()), height: Int(room.height.rounded()))
        send(.displayControl, payload: Wire.encode(control))
    }

    /// Disconnect: `end`, then the connection closes once it is sent (or after a second).
    func endDisplays(closing c: NWConnection) {
        let message = StreamMessage(kind: .displayControl, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                    payload: Wire.encode(DisplayControl(action: DisplayControl.end)))
        c.send(content: message.serialized(), completion: .contentProcessed { _ in c.cancel() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.cancel() }
    }

    /// The display a new one became, once the Mac lists it: streamed.
    func showNewDisplay() {
        guard let before = pendingNewDisplay,
              let new = extendedDisplays.first(where: { !before.contains($0.id) }) else { return }
        pendingNewDisplay = nil
        select(.display(new.id))
    }

    // MARK: Each display's settings, per Mac

    /// The source this device asked for (`displaySettingsArriving`) is a display whose memory can be
    /// read: once the Mac's settings and, for an extended display, its list are in, its settings go to
    /// the Mac, or a display new to this device remembers the Mac's (DisplaySettingsMemory).
    func applyDisplaySettings() {
        guard let source = displaySettingsArriving, let macID = session?.macID, let shown = settings.displayed else { return }
        guard hostMakesDisplays else { displaySettingsArriving = nil; return }
        guard let key = DisplaySettingsMemory.key(source, displays: extendedDisplays, away: session?.route.isRemote ?? false) else {
            // A display the Mac has not listed yet waits for its list; a window brings nothing back.
            if case .display = source { return }
            displaySettingsArriving = nil
            return
        }
        displaySettingsArriving = nil
        var all = Self.displaySettings(macID)
        let (change, remember) = DisplaySettingsMemory.arriving(all[key], shown: shown)
        if all[key] != remember {
            all[key] = remember
            Self.setDisplaySettings(all, macID)
        }
        if let change {
            #if DEBUG
            print("displays: \(key)'s settings back: \(change.fields)")
            #endif
            sendSettings(change)
        }
    }

    /// The person's pick of Resolution, Frame Rate or Quality, kept for the display showing now.
    func rememberDisplaySettings(_ change: HostSettingsChange) {
        guard hostMakesDisplays, change.captureScale != nil || change.maxFPS != nil || change.bitrate != nil,
              let macID = session?.macID, let shown = settings.displayed,
              let key = DisplaySettingsMemory.key(active, displays: extendedDisplays, away: session?.route.isRemote ?? false)
        else { return }
        var all = Self.displaySettings(macID)
        all[key] = DisplaySettingsMemory.recording(change, into: all[key], shown: shown)
        Self.setDisplaySettings(all, macID)
    }

    private static func settingsKey(_ macID: String) -> String { "Sill.displaySettings.\(macID)" }

    static func displaySettings(_ macID: String) -> [String: DisplaySettings] {
        guard let data = UserDefaults.standard.data(forKey: settingsKey(macID)) else { return [:] }
        return (try? JSONDecoder().decode([String: DisplaySettings].self, from: data)) ?? [:]
    }

    static func setDisplaySettings(_ all: [String: DisplaySettings], _ macID: String) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey(macID))
    }

    // MARK: Which display this device last watched, per Mac

    /// The person's pick: a display is remembered for this Mac's next connection, the Mac's own
    /// forgets it; a window leaves it as it is.
    func noteShown(_ source: StreamSource) {
        guard let macID = session?.macID else { return }
        switch source {
        case .display(let id): Self.setLastDisplay(id, macID)
        case .desktop: Self.setLastDisplay(nil, macID)
        case .none, .window: break
        }
    }

    /// A connection's first pick: the display this device last watched on this Mac, else its own.
    func firstSource() -> StreamSource {
        guard hostMakesDisplays, let macID = session?.macID, let id = Self.lastDisplay(macID) else { return .desktop }
        return .display(id)
    }

    private static func key(_ macID: String) -> String { "Sill.lastDisplay.\(macID)" }

    static func lastDisplay(_ macID: String) -> UInt32? {
        (UserDefaults.standard.object(forKey: key(macID)) as? NSNumber).map { $0.uint32Value }
    }

    static func setLastDisplay(_ id: UInt32?, _ macID: String) {
        if let id { UserDefaults.standard.set(NSNumber(value: id), forKey: key(macID)) }
        else { UserDefaults.standard.removeObject(forKey: key(macID)) }
    }
}
