import Foundation
import AppKit
import Network
import ScreenCaptureKit
import StreamProtocol

/// The extended displays, the host's side (kinds 49 to 51; docs/displays-plan.md). Each device that
/// subscribes (any kind 50) has up to `DisplayPolicy.maxPerDevice` of its own, made with the private
/// CGVirtualDisplay API (VirtualDisplay.swift) at the size it asked, each with a serial number of its
/// own (`DisplayPolicy.serial`), so macOS puts it back where it was in System Settings › Displays.
///
/// - Subscribing brings back the displays the device had when it last left, and the windows that
///   were on them, unless they were moved on the Mac meanwhile (`DisplayPolicy.returns`).
/// - `add` makes one, `remove` takes one away for good, `end` (Disconnect) takes all of the device's
///   away now, to come back next time. A connection that is lost keeps them `DisplayList.grace`
///   seconds, so a reconnect finds them as they were.
/// - What streams is the coordinator's: it asks `ready` for a display to stream, and hears of one
///   that went (`onGone`).
/// - While a device subscribes, every `thumbnailEvery` its displays' pictures and the Mac's own go to
///   it (kind 51), for its Displays sheet.
/// - A synthetic host never makes a display on this Mac: its displays are entries alone, streamed as
///   the test pattern at their size, and nothing is remembered on disk.
///
/// Main actor: VirtualDisplay must be made and released there (its event loop).
@MainActor
final class ExtendedDisplays {
    /// The window lists' `displays`: nil when this host cannot make them.
    var advertised: Int? { available ? DisplayControl.generation : nil }
    let available: Bool
    /// A display that was streaming went: the coordinator streams the Mac's own instead.
    var onGone: ((UInt32) -> Void)?
    /// A display made again at a new size is up: the coordinator starts its stream again.
    var onRemade: ((UInt32) -> Void)?
    /// Displays being made again at a new size (`resize`): their capture's stop is not an end.
    private(set) var remaking: Set<UInt32> = []

    private let server: StreamServer
    private let synthetic: Bool
    private var memory = DisplayPolicy.Memory()
    /// Where `memory` is kept; nil on a synthetic host.
    private let file: URL?

    struct Live {
        let id: UInt32
        let owner: String
        let slot: Int
        let width: Int
        let height: Int
        /// Sized as the Mac's own display.
        var matchesPrimary: Bool?
        /// Nil on a synthetic host, and while it is being made.
        var display: VirtualDisplay?
        /// Its place among its owner's displays (DisplayPolicy.name), kept by `live`'s observer.
        var name = ""
    }
    private var live: [UInt32: Live] = [:] {
        didSet {
            // Renumbered at every change, so the names close up behind a display removed.
            for (id, d) in live {
                let name = DisplayPolicy.name(slot: d.slot, among: live.values.filter { $0.owner == d.owner }.map(\.slot))
                if d.name != name { live[id]?.name = name }
            }
        }
    }
    /// Displays being made, which `ready` waits for.
    private var making: [UInt32: Task<Void, Never>] = [:]

    private struct Subscriber {
        let connection: NWConnection
        let owner: String
        let who: String
        /// Its last `add` made nothing: why, for its next list.
        var problem: String?
    }
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    /// A lost connection's displays, waiting out the grace.
    private var leaving: [String: Task<Void, Never>] = [:]
    private var thumbnails: Task<Void, Never>?
    static let thumbnailEvery: Duration = .seconds(5)

    init(server: StreamServer, synthetic: Bool, available: Bool) {
        self.server = server
        self.synthetic = synthetic
        self.available = available
        if synthetic {
            file = nil
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            file = support?.appendingPathComponent("Sill", isDirectory: true).appendingPathComponent("Displays.json")
            if let file, let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode(DisplayPolicy.Memory.self, from: data) {
                memory = saved
            }
        }
    }

    // MARK: What the coordinator asks

    /// The display `id` once it is up (it may be coming back for a device that just subscribed), or
    /// nil: no such display, or it could not be made.
    func ready(_ id: UInt32) async -> Live? {
        if let task = making[id] { await task.value }
        guard let d = live[id], synthetic || d.display?.isAlive == true else { return nil }
        return d
    }

    /// The display `id` as it is now (nil while it is being made).
    func current(_ id: UInt32) -> Live? { live[id] }

    /// Where display `id` is, in global points: its bounds, or a synthetic display's own size.
    func bounds(_ id: UInt32) -> CGRect? {
        guard let d = live[id] else { return nil }
        if synthetic { return CGRect(x: 0, y: 0, width: d.width, height: d.height) }
        guard let b = d.display?.bounds, b.width > 0 else { return nil }
        return b
    }

    /// `owner`'s displays, in their order (slot), as its Displays sheet lists them.
    func owned(by owner: String) -> [UInt32] {
        live.values.filter { $0.owner == owner }.sorted { $0.slot < $1.slot }.map(\.id)
    }

    /// The CoreGraphics display of `id`.
    func displayID(_ id: UInt32) -> CGDirectDisplayID? {
        guard let d = live[id]?.display, d.displayID != 0 else { return nil }
        return d.displayID
    }

    // MARK: A device's message

    /// A kind 50 from `connection`, whose owner is `owner` (DisplayPolicy.owner) when this subscribes it,
    /// named `who`.
    func received(_ payload: Data, from connection: NWConnection, owner: String, who: String) async {
        guard available, let control = Wire.decode(DisplayControl.self, from: payload) else { return }
        let id = ObjectIdentifier(connection)
        if subscribers[id] == nil { subscribe(connection, owner: owner, who: who) }
        // A connection's owner is the one it subscribed as: a name can change under it (its stats).
        let owner = subscribers[id]?.owner ?? owner
        // Its last add's problem holds until its next action.
        if control.action != nil { subscribers[id]?.problem = nil }
        switch control.action {
        case nil:
            break
        case DisplayControl.add?:
            let used = Set(live.values.filter { $0.owner == owner }.map(\.slot))
            guard let slot = DisplayPolicy.nextSlot(used: used) else {
                subscribers[id]?.problem = "limit"
                break
            }
            let size = DisplayPolicy.size(width: control.width, height: control.height)
            let saved = DisplayPolicy.Memory.Slot(slot: slot, width: size.width, height: size.height)
            memory.owners[owner, default: .init()].slots.removeAll { $0.slot == slot }
            memory.owners[owner, default: .init()].slots.append(saved)
            // A slot made again starts empty: windows kept from a display removed for good never land on it.
            memory.owners[owner]?.windows.removeAll { $0.slot == slot }
            save()
            let newID = make(saved, owner: owner)
            let name = live[newID]?.name ?? "a display"
            sendList()
            await making[newID]?.value
            if live[newID]?.display == nil, !synthetic { subscribers[id]?.problem = "failed" }
            print("Displays: \(who) added \(name), \(size.width)×\(size.height) pt.")
        case DisplayControl.resize?:
            guard let shown = control.id, let d = live[shown], d.owner == owner else { break }
            let saved = DisplayPolicy.resized(control, slot: d.slot, primary: Self.primary)
            guard saved != memory.owners[owner]?.slots.first(where: { $0.slot == d.slot }) else { break }
            memory.owners[owner, default: .init()].slots.removeAll { $0.slot == d.slot }
            memory.owners[owner, default: .init()].slots.append(saved)
            save()
            let name = d.name
            // Made again with the same serial: macOS keeps it where it was arranged, and the windows on
            // it are kept and put back as at a reconnect.
            remaking.insert(shown)
            defer { remaking.remove(shown) }
            take(shown, ending: .disconnect, waitForFall: false, announce: false)
            // A moment for macOS to let go of the serial and move the windows off.
            if !synthetic { try? await Task.sleep(for: .seconds(1)) }
            // Removed, or its device gone, meanwhile: it stays gone.
            guard subscribers[id] != nil, memory.owners[owner]?.slots.contains(saved) == true else { break }
            make(saved, owner: owner)
            sendList()
            await making[shown]?.value
            if live[shown]?.display == nil, !synthetic { subscribers[id]?.problem = "failed" }
            print("Displays: \(who) resized \(name) to \(saved.width)×\(saved.height) pt"
                  + (saved.matchesPrimary == true ? ", as the Mac's own display." : "."))
            onRemade?(shown)
        case DisplayControl.remove?:
            guard let shown = control.id, let d = live[shown], d.owner == owner else { break }
            memory.owners[owner]?.slots.removeAll { $0.slot == d.slot }
            memory.owners[owner]?.windows.removeAll { $0.slot == d.slot }
            save()
            take(shown, ending: .removed)
            print("Displays: \(who) removed \(d.name).")
        case DisplayControl.end?:
            // Disconnect: the connection ends next, and `clientLeft` finds nothing to wait for.
            let mine = live.values.filter { $0.owner == owner }
            for d in mine { take(d.id, ending: .disconnect) }
            if !mine.isEmpty { print("Displays: \(who) disconnected; its \(mine.count == 1 ? "display goes" : "\(mine.count) displays go") until it is back.") }
            subscribers[id] = nil
            stopThumbnailsIfIdle()
            return
        default:
            return
        }
        sendList()
    }

    /// `connection` is gone. A lost one's displays stay `DisplayList.grace` seconds for its reconnect,
    /// unless another of its device's connections still subscribes.
    func clientLeft(_ connection: NWConnection) {
        guard let s = subscribers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        stopThumbnailsIfIdle()
        let owner = s.owner
        guard !subscribers.values.contains(where: { $0.owner == owner }), live.values.contains(where: { $0.owner == owner }) else { return }
        let wait = DisplayPolicy.keepFor(.lost)
        leaving[owner]?.cancel()
        leaving[owner] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.leaving[owner] = nil
            guard !self.subscribers.values.contains(where: { $0.owner == owner }) else { return }
            let mine = self.live.values.filter { $0.owner == owner }
            for d in mine { self.take(d.id, ending: .lost) }
            print("Displays: \(s.who) did not come back in \(Int(wait)) s; its displays go until it is back.")
        }
    }

    /// Quit or a signal: every display goes (the process is about to end, which would take them),
    /// its windows kept to come back next time.
    func shutdown() {
        for d in Array(live.values) { take(d.id, ending: .disconnect, waitForFall: false) }
        thumbnails?.cancel()
    }

    // MARK: Subscribing

    private func subscribe(_ connection: NWConnection, owner: String, who: String) {
        subscribers[ObjectIdentifier(connection)] = Subscriber(connection: connection, owner: owner, who: who)
        // Back within the grace: everything is as it was.
        leaving.removeValue(forKey: owner)?.cancel()
        let saved = memory.owners[owner]?.slots ?? []
        var brought = 0
        for slot in saved.sorted(by: { $0.slot < $1.slot }) {
            let id = DisplayPolicy.serial(owner: owner, slot: slot.slot)
            guard live[id] == nil else { continue }
            make(DisplayPolicy.bringingBack(slot, primary: Self.primary), owner: owner)
            brought += 1
        }
        if brought > 0 { print("Displays: \(who) is back; bringing back \(brought == 1 ? "its display" : "its \(brought) displays").") }
        startThumbnails()
    }

    // MARK: Making and taking away

    /// Makes slot `s` of `owner` (on a synthetic host, only its entry), then puts back the windows
    /// kept from it. Returns its id at once; `making` holds the work until it is up.
    @discardableResult
    private func make(_ s: DisplayPolicy.Memory.Slot, owner: String) -> UInt32 {
        let id = DisplayPolicy.serial(owner: owner, slot: s.slot)
        live[id] = Live(id: id, owner: owner, slot: s.slot, width: s.width, height: s.height,
                        matchesPrimary: s.matchesPrimary, display: nil)
        guard !synthetic else { return id }
        making[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.making[id] = nil }
            do {
                // Named as it is now; a later renumbering reaches macOS when it is made again.
                let name = self.live[id]?.name ?? "Display"
                let d = try VirtualDisplay(name: "Oriel \(name)", widthPt: s.width, heightPt: s.height,
                                           scale: s.scale ?? 2, refreshHz: 60, vendorID: DisplayPolicy.vendorID,
                                           productID: DisplayPolicy.productID, serialNum: id)
                d.onTerminated = { [weak self] in Task { @MainActor in self?.terminated(id) } }
                let online = await d.waitUntilOnline()
                // Taken away while it came up (a remove, the device's Disconnect): let it go.
                guard self.live[id] != nil else { d.destroy(); return }
                self.live[id]?.display = d
                print("Displays: \(name) is up at \(Int(d.bounds.width))×\(Int(d.bounds.height)) pt"
                      + (online ? "" : " (not yet at the size asked)") + ", at \(Int(d.bounds.minX)),\(Int(d.bounds.minY)).")
                self.putBack(owner: owner, slot: s.slot, on: d.bounds)
            } catch {
                print("Displays: \(self.live[id]?.name ?? "a display") could not be made: \(error).")
                self.live[id] = nil
            }
            self.sendList()
        }
        return id
    }

    /// Takes display `id` away. Its windows are kept to come back with it unless it goes for good
    /// (`DisplayPolicy.keepsWindows`), with where macOS put them a moment later (`waitForFall`).
    /// `announce` false: no `onGone`, as for a display made again at once (`resize`).
    private func take(_ id: UInt32, ending: DisplayPolicy.Ending, waitForFall: Bool = true, announce: Bool = true) {
        guard let d = live.removeValue(forKey: id) else { return }
        making.removeValue(forKey: id)?.cancel()
        var kept: [DisplayPolicy.Kept] = []
        if let vd = d.display, vd.isAlive, DisplayPolicy.keepsWindows(ending) {
            kept = Self.windows(on: vd.bounds, slot: d.slot)
            memory.owners[d.owner, default: .init()].windows.removeAll { $0.slot == d.slot }
            memory.owners[d.owner, default: .init()].windows.append(contentsOf: kept)
            save()
        }
        d.display?.destroy()
        if announce { onGone?(id) }
        sendList()
        guard waitForFall, !kept.isEmpty else { return }
        // Where macOS put each: a window still there when the display comes back goes back on it.
        let owner = d.owner
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            for k in kept {
                guard let i = self.memory.owners[owner]?.windows.firstIndex(where: { $0.windowID == k.windowID && $0.slot == k.slot }) else { continue }
                self.memory.owners[owner]?.windows[i].fellTo = WindowSizer.liveBounds(of: k.windowID)
            }
            self.save()
        }
    }

    /// The system took display `id` away by itself.
    private func terminated(_ id: UInt32) {
        guard live[id] != nil else { return }
        print("Displays: the system removed \(live[id]?.name ?? "a display").")
        take(id, ending: .disconnect)
    }

    /// The windows on `bounds` (Sill's own excepted), as kept for slot `slot`.
    private static func windows(on bounds: CGRect, slot: Int) -> [DisplayPolicy.Kept] {
        guard bounds.width > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != WindowCatalog.ownPID,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b as CFDictionary),
                  frame.width > 40, frame.height > 40, DisplayPolicy.isOn(frame, display: bounds) else { return nil }
            return DisplayPolicy.Kept(slot: slot, windowID: number, pid: pid,
                                      app: info[kCGWindowOwnerName as String] as? String ?? "?",
                                      title: info[kCGWindowName as String] as? String ?? "",
                                      offset: CGPoint(x: frame.minX - bounds.minX, y: frame.minY - bounds.minY),
                                      size: frame.size, fellTo: nil)
        }
    }

    /// Puts the windows kept from `slot` back on its display at `bounds`, through Accessibility; the
    /// records go either way.
    private func putBack(owner: String, slot: Int, on bounds: CGRect) {
        guard var o = memory.owners[owner] else { return }
        let mine = o.windows.filter { $0.slot == slot }
        guard !mine.isEmpty else { return }
        o.windows.removeAll { $0.slot == slot }
        memory.owners[owner] = o
        save()
        guard AXIsProcessTrusted(), bounds.width > 0 else { return }
        var back = 0
        for k in mine {
            let now = WindowSizer.liveBounds(of: k.windowID)
            guard DisplayPolicy.returns(k, now: now), let now,
                  let element = WindowSizer.axWindow(pid: k.pid, frame: now) else { continue }
            if WindowSizer.setPosition(element, DisplayPolicy.placed(k, on: bounds)) == .success { back += 1 }
        }
        if back > 0 { print("Displays: \(back == 1 ? "1 window" : "\(back) windows") back on \(live.values.first { $0.owner == owner && $0.slot == slot }?.name ?? "its display").") }
    }

    /// The Mac's own display: what `match` "primary" makes a display as.
    private static var primary: DisplayPolicy.Primary {
        let id = CGMainDisplayID()
        let size = CGDisplayBounds(id).size
        return DisplayPolicy.Primary(width: size.width, height: size.height,
                                     pixelWidth: CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(size.width * 2))
    }

    private func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(memory) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: To the devices

    private func list(for s: Subscriber) -> DisplayList {
        let mine = live.values.filter { $0.owner == s.owner }.sorted { $0.slot < $1.slot }
        return DisplayList(displays: mine.map { ExtendedDisplay(id: $0.id, name: $0.name, width: $0.width, height: $0.height,
                                                                      matchesPrimary: $0.matchesPrimary) },
                           max: DisplayPolicy.maxPerDevice, problem: s.problem)
    }

    private func sendList() {
        let now = Date().timeIntervalSince1970
        let messages = subscribers.values.map { s in
            (s.connection, StreamMessage(kind: .displays, timestamp: now, isKeyframe: false, payload: Wire.encode(list(for: s))))
        }
        if !messages.isEmpty { server.send(each: messages) }
    }

    /// Each subscriber's displays and the Mac's own, small, every `thumbnailEvery`. Sill's own windows
    /// (the pairing code) never show in them.
    private func startThumbnails() {
        guard thumbnails == nil, !synthetic else { return }
        thumbnails = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sendThumbnails()
                try? await Task.sleep(for: Self.thumbnailEvery)
            }
        }
    }

    private func stopThumbnailsIfIdle() {
        guard subscribers.isEmpty else { return }
        thumbnails?.cancel()
        thumbnails = nil
    }

    /// Display `did`, small (480 points wide), as a JPEG, without the cursor or Sill's own windows (the
    /// pairing code): a display's thumbnail, and a desktop's (HostDesktops).
    static func shot(_ did: CGDirectDisplayID, in content: SCShareableContent) async -> Data? {
        guard let d = content.displays.first(where: { $0.displayID == did }) else { return nil }
        let own = content.applications.filter { $0.processID == WindowCatalog.ownPID }
        let config = SCStreamConfiguration()
        let width = 480.0
        config.width = Int(width)
        config.height = max(2, Int(width * Double(d.height) / Double(max(d.width, 1))))
        config.showsCursor = false
        let filter = SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return WindowCatalog.jpeg(image, quality: 0.6)
    }

    private func sendThumbnails() async {
        guard !subscribers.isEmpty, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        var pictures: [UInt32: Data] = [:]
        func picture(_ id: UInt32, _ did: CGDirectDisplayID) async {
            if let jpeg = await Self.shot(did, in: content) { pictures[id] = jpeg }
        }
        await picture(0, CGMainDisplayID())
        for d in live.values {
            guard let did = d.display?.displayID, did != 0 else { continue }
            await picture(d.id, did)
        }
        let now = Date().timeIntervalSince1970
        var messages: [(NWConnection, StreamMessage)] = []
        for s in subscribers.values {
            for (id, jpeg) in pictures where id == 0 || live[id]?.owner == s.owner {
                messages.append((s.connection, StreamMessage(kind: .displayThumbnail, timestamp: now, isKeyframe: false,
                                                             payload: ImageBlob.encodeThumbnail(windowID: id, jpeg: jpeg))))
            }
        }
        if !messages.isEmpty { server.send(each: messages) }
    }
}
