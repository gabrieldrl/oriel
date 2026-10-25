import Foundation
import AppKit
import Network
import ScreenCaptureKit
import StreamProtocol

/// The Mac's desktops, the host's side (kinds 53 to 55; Desktops.swift, docs/desktops-plan.md). A
/// device that subscribes (a kind 54 `{}`) gets the Mac's own display's desktops and its own extended
/// displays' (kind 53), again whenever they change, and each desktop's picture while it shows (kind
/// 55). A kind 54 with a display and a space switches that display to it, one Move left or right a
/// space at a time, each after the last one landed (DesktopPolicy.steps).
///
/// - What changes is read every `pollEvery` while a device subscribes, and at once when macOS says the
///   space changed.
/// - A synthetic host reads and posts nothing on this Mac: its desktops are three and a full-screen
///   "Safari" on its own display and one on each extended display, a switch lands at once, and each
///   picture is a flat colour.
///
/// Main actor, as the coordinator and ExtendedDisplays are.
@MainActor
final class HostDesktops {
    /// The window lists' `desktops`: nil when this host cannot list them.
    var advertised: Int? { available ? DesktopControl.generation : nil }
    let available: Bool
    /// Posts one step's shortcut (the Mac's Move left or right a space); false when that shortcut is
    /// off or has no key, so nothing was posted. The coordinator's.
    var postStep: ((DesktopPolicy.Step) -> Bool)?
    /// Moves the pointer to a point (global points), as Sill's own motion. The coordinator's.
    var movePointer: ((CGPoint) -> Void)?

    static let pollEvery: Duration = .seconds(1)
    /// Pictures every this many polls, as the displays' thumbnails (ExtendedDisplays.thumbnailEvery).
    static let picturesEvery = 5
    /// After a switch lands, its desktop's picture this long after (the slide is over).
    static let pictureAfterSwitch: Duration = .milliseconds(800)

    private let server: StreamServer
    private let synthetic: Bool
    private let displays: ExtendedDisplays

    private struct Subscriber {
        let connection: NWConnection
        let owner: String
        let who: String
        var sent: DesktopList?
    }
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var poll: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?
    private var switching: Task<Void, Never>?
    /// A synthetic host's current space per display.
    private var syntheticCurrent: [UInt32: UInt64] = [:]

    init(server: StreamServer, synthetic: Bool, displays: ExtendedDisplays) {
        self.server = server
        self.synthetic = synthetic
        self.displays = displays
        available = synthetic || MacSpaces.available
    }

    // MARK: A device's message

    /// A kind 54 from `connection`, whose owner is `owner` (DisplayPolicy.owner), named `who`.
    func received(_ payload: Data, from connection: NWConnection, owner: String, who: String) {
        guard available, let control = Wire.decode(DesktopControl.self, from: payload) else { return }
        let id = ObjectIdentifier(connection)
        if subscribers[id] == nil {
            subscribers[id] = Subscriber(connection: connection, owner: owner, who: who)
            start()
        }
        if let display = control.display, let space = control.id {
            switchTo(space, on: display, for: id)
        } else {
            refresh()
        }
    }

    /// `connection` is gone.
    func clientLeft(_ connection: NWConnection) {
        guard subscribers.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        if subscribers.isEmpty { stop() }
    }

    func shutdown() {
        stop()
        subscribers = [:]
    }

    // MARK: Watching

    private func start() {
        guard poll == nil else { return }
        poll = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                if tick % Self.picturesEvery == 0 { await self.sendPictures() }
                tick += 1
                try? await Task.sleep(for: Self.pollEvery)
            }
        }
        guard !synthetic else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stop() {
        poll?.cancel()
        poll = nil
        switching?.cancel()
        switching = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    /// Each subscriber's list, sent when it changed.
    private func refresh() {
        guard !subscribers.isEmpty else { return }
        let sets = readSets()
        var messages: [(NWConnection, StreamMessage)] = []
        let now = Date().timeIntervalSince1970
        for (key, s) in subscribers {
            let list = DesktopPolicy.list(assigned(sets, owner: s.owner), owned: displays.owned(by: s.owner), appName: appName)
            guard list != s.sent else { continue }
            subscribers[key]?.sent = list
            messages.append((s.connection, StreamMessage(kind: .desktops, timestamp: now, isKeyframe: false, payload: Wire.encode(list))))
        }
        if !messages.isEmpty { server.send(each: messages) }
    }

    // MARK: The spaces

    private func readSets() -> [DesktopPolicy.DisplaySpaces] {
        guard synthetic else { return MacSpaces.read() ?? [] }
        var sets = [DesktopPolicy.DisplaySpaces(uuid: Self.syntheticMain,
                                                current: syntheticCurrent[DesktopControl.macDisplay] ?? 1,
                                                spaces: [.init(id: 1), .init(id: 2), .init(id: 3),
                                                         .init(id: 4, fullScreen: true, pid: Self.syntheticSafari)])]
        for s in subscribers.values {
            for id in displays.owned(by: s.owner) where !sets.contains(where: { $0.uuid == Self.syntheticUUID(id) }) {
                let only = UInt64(id) << 8 | 1
                sets.append(.init(uuid: Self.syntheticUUID(id), current: syntheticCurrent[id] ?? only, spaces: [.init(id: only)]))
            }
        }
        return sets
    }

    private static let syntheticMain = "synthetic-main"
    private static let syntheticSafari: Int32 = -1
    private static func syntheticUUID(_ id: UInt32) -> String { "synthetic-\(id)" }

    /// Which set is which of `owner`'s displays.
    private func assigned(_ sets: [DesktopPolicy.DisplaySpaces], owner: String) -> [UInt32: DesktopPolicy.DisplaySpaces] {
        let owned = displays.owned(by: owner)
        if synthetic {
            return DesktopPolicy.assign(sets, mainUUID: Self.syntheticMain, displays: owned.map { ($0, Self.syntheticUUID($0)) })
        }
        let theirs: [(id: UInt32, uuid: String)] = owned.compactMap { id in
            guard let did = displays.displayID(id), let uuid = MacSpaces.uuid(did) else { return nil }
            return (id, uuid)
        }
        return DesktopPolicy.assign(sets, mainUUID: MacSpaces.uuid(CGMainDisplayID()), displays: theirs)
    }

    private func appName(_ pid: Int32) -> String? {
        if synthetic { return pid == Self.syntheticSafari ? "Safari" : nil }
        return MacSpaces.appName(pid)
    }

    /// Display `display`'s set as `owner` sees it, read now.
    private func set(_ display: UInt32, owner: String) -> DesktopPolicy.DisplaySpaces? {
        assigned(readSets(), owner: owner)[display]
    }

    /// Where `display` is, in global points.
    private func bounds(_ display: UInt32) -> CGRect? {
        display == DesktopControl.macDisplay ? CGDisplayBounds(CGMainDisplayID()) : displays.bounds(display)
    }

    private func displayName(_ display: UInt32) -> String {
        display == DesktopControl.macDisplay ? "the Mac's display" : (displays.current(display)?.name ?? "a display")
    }

    // MARK: Switching

    /// Switches `display` to `space` for subscriber `key`, replacing a switch still stepping.
    private func switchTo(_ space: UInt64, on display: UInt32, for key: ObjectIdentifier) {
        guard let s = subscribers[key] else { return }
        // Only the Mac's own display and the device's own.
        guard display == DesktopControl.macDisplay || displays.owned(by: s.owner).contains(display) else { return }
        switching?.cancel()
        switching = Task { @MainActor [weak self] in
            await self?.step(to: space, on: display, owner: s.owner, who: s.who)
        }
    }

    private func step(to space: UInt64, on display: UInt32, owner: String, who: String) async {
        guard let start = set(display, owner: owner) else { return }
        let named = DesktopPolicy.named(start.spaces, appName: appName)
        let name = named.first { $0.id == space }?.name ?? "a desktop"
        if synthetic {
            guard start.spaces.contains(where: { $0.id == space }) else { return }
            syntheticCurrent[display] = space
            refresh()
            print("Desktops: \(who) switched \(displayName(display)) to \(name).")
            await pictureSoon()
            return
        }
        guard let (direction, count) = DesktopPolicy.steps(from: start.current, to: space, in: start.spaces) else {
            if start.current != space { print("Desktops: \(who) asked for \(name), which \(displayName(display)) cannot reach from where it is.") }
            return
        }
        // The shortcut moves the display the pointer is on.
        if let b = bounds(display), b.width > 0,
           let at = CGEvent(source: nil)?.location, !b.contains(at) {
            movePointer?(CGPoint(x: b.midX, y: b.midY))
        }
        var taken = 0
        for _ in 0..<count {
            guard !Task.isCancelled else { return }
            let before = set(display, owner: owner)?.current
            guard postStep?(direction) == true else {
                print("Desktops: \(direction == .right ? "Move right a space" : "Move left a space") is off in this Mac's Keyboard Shortcuts (Mission Control); \(who)'s switch to \(name) stopped.")
                break
            }
            let deadline = Date().addingTimeInterval(DesktopPolicy.stepTimeout)
            var moved = false
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if set(display, owner: owner)?.current != before { moved = true; break }
            }
            guard moved else {
                print("Desktops: \(displayName(display)) did not move after \(taken) of \(count) steps; \(who)'s switch to \(name) stopped.")
                break
            }
            taken += 1
        }
        refresh()
        if taken == count {
            print("Desktops: \(who) switched \(displayName(display)) to \(name) (\(count == 1 ? "1 step" : "\(count) steps")).")
        }
        await pictureSoon()
    }

    private func pictureSoon() async {
        try? await Task.sleep(for: Self.pictureAfterSwitch)
        guard !Task.isCancelled else { return }
        await sendPictures()
    }

    // MARK: Pictures

    /// The picture of each display's desktop showing, for every subscriber that sees that display; a
    /// picture taken across a switch is nobody's (DesktopPolicy.tagged).
    private func sendPictures() async {
        guard !subscribers.isEmpty else { return }
        var wanted: [UInt32: [ObjectIdentifier]] = [:]
        for (key, s) in subscribers {
            for d in [DesktopControl.macDisplay] + displays.owned(by: s.owner) { wanted[d, default: []].append(key) }
        }
        let content: SCShareableContent?
        if synthetic {
            content = nil
        } else {
            guard CGPreflightScreenCaptureAccess() else { return }
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard content != nil else { return }
        }
        var messages: [(NWConnection, StreamMessage)] = []
        let now = Date().timeIntervalSince1970
        for (display, keys) in wanted {
            guard let owner = keys.first.flatMap({ subscribers[$0]?.owner }) else { continue }
            let before = set(display, owner: owner)?.current
            let jpeg: Data?
            if synthetic {
                jpeg = before.flatMap(Self.syntheticPicture)
            } else if let content, let did = display == DesktopControl.macDisplay ? CGMainDisplayID() : displays.displayID(display) {
                jpeg = await ExtendedDisplays.shot(did, in: content)
            } else {
                jpeg = nil
            }
            guard let jpeg, let space = DesktopPolicy.tagged(before: before, after: set(display, owner: owner)?.current) else { continue }
            let payload = ImageBlob.encodeDesktopThumbnail(spaceID: space, jpeg: jpeg)
            for key in keys {
                guard let c = subscribers[key]?.connection else { continue }
                messages.append((c, StreamMessage(kind: .desktopThumbnail, timestamp: now, isKeyframe: false, payload: payload)))
            }
        }
        if !messages.isEmpty { server.send(each: messages) }
    }

    /// A synthetic desktop's picture: a flat colour of its own.
    private static func syntheticPicture(_ space: UInt64) -> Data? {
        let width = 480, height = 300
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let hue = CGFloat(space % 7) / 7
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.7, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage().flatMap { WindowCatalog.jpeg($0, quality: 0.6) }
    }
}
