import Foundation
import AppKit
import Network
import StreamProtocol

/// The Mac's screen off and its own input away while a device works it (kind 52; Curtain.swift,
/// docs/curtain-plan.md). Up while any connection wants it, down the moment none does (its
/// `off`, its connection gone, Sill quitting), so no device leaves the Mac dark and locked behind it.
///
/// Up, it is three things:
/// - An event tap at the HID level, on a thread of its own, dropping the Mac's own keyboard,
///   trackpad, mouse and system keys; every event Sill posts carries `CurtainPolicy.marker` and goes
///   through. A tap needs Accessibility: without it nothing goes up and the device hears why.
/// - A black window over each of the Mac's own displays (not Sill's virtual ones), above everything,
///   that clicks pass through. Sill's own windows are in no capture, so the devices see the Mac as before.
/// - The built-in display's brightness at 0 (DisplayServices), set again every few seconds against
///   automatic brightness, and put back as it was when it comes down.
///
/// A synthetic host only keeps the state: nothing on this Mac changes. Main actor: AppKit's windows.
@MainActor
final class MacCurtain {
    /// The window lists' `curtain`: nil when this host cannot.
    var advertised: Int? { available ? CurtainControl.generation : nil }
    let available: Bool
    /// The black windows went up: a stream of the Mac's own display started before them has them in
    /// its picture (a running SCStream's filter left out only the windows Sill had then), so it starts
    /// again, leaving them out.
    var onCovered: (() -> Void)?

    private let server: StreamServer
    private let synthetic: Bool
    private var wanting: [ObjectIdentifier: NWConnection] = [:]
    private(set) var isUp = false
    private var problem: String?
    private var tap: CurtainTap?
    private var windows: [NSWindow] = []
    private var brightness: [CGDirectDisplayID: Float] = [:]
    private var keepDark: Timer?
    private var screens: NSObjectProtocol?

    init(server: StreamServer, synthetic: Bool, available: Bool) {
        self.server = server
        self.synthetic = synthetic
        self.available = available
    }

    /// A kind 52 from `connection`, named `who`.
    func received(_ payload: Data, from connection: NWConnection, who: String) {
        guard available, let control = Wire.decode(CurtainControl.self, from: payload) else { return }
        let id = ObjectIdentifier(connection)
        if control.on { wanting[id] = connection } else { wanting[id] = nil }
        update(who: who)
        // `update` answers every device that wants it; one that turned it off hears so here.
        if !control.on { answer(connection) }
    }

    /// `connection` is gone: what it wanted goes with it.
    func clientLeft(_ connection: NWConnection) {
        guard wanting.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        update(who: nil)
    }

    /// Sill is quitting: down now.
    func shutdown() {
        wanting = [:]
        if isUp { lower() }
    }

    private func update(who: String?) {
        if !wanting.isEmpty, !isUp {
            raise()
            if isUp { print("Curtain: \(who ?? "a device") turned the Mac's screen off; its own keyboard and trackpad do nothing.") }
            else { print("Curtain: \(who ?? "a device") asked for the Mac's screen off, but Sill may not control this Mac (Accessibility).") }
        } else if wanting.isEmpty, isUp {
            lower()
            print("Curtain: the Mac's screen is back, with its keyboard and trackpad.")
        }
        // Every device that wants it hears the state.
        for c in wanting.values { answer(c) }
    }

    private func answer(_ connection: NWConnection) {
        let mine = wanting[ObjectIdentifier(connection)] != nil
        let state = CurtainControl(on: mine && isUp, problem: mine && !isUp ? problem : nil)
        server.send(StreamMessage(kind: .curtain, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                                  payload: Wire.encode(state)), to: connection)
    }

    // MARK: Up and down

    private func raise() {
        problem = nil
        guard !synthetic else { isUp = true; return }
        guard AXIsProcessTrusted(), let tap = CurtainTap() else {
            problem = CurtainControl.accessibility
            return
        }
        self.tap = tap
        isUp = true
        cover()
        dim()
        keepDark = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dim() }
        }
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cover() }
        }
    }

    private func lower() {
        isUp = false
        tap?.stop()
        tap = nil
        keepDark?.invalidate()
        keepDark = nil
        if let screens { NotificationCenter.default.removeObserver(screens) }
        screens = nil
        for w in windows { w.orderOut(nil) }
        windows = []
        for (id, level) in brightness { _ = Brightness.set?(id, level) }
        brightness = [:]
    }

    /// Black over each of the Mac's own displays, made again when they change.
    private func cover() {
        guard isUp else { return }
        for w in windows { w.orderOut(nil) }
        windows = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  !StreamCoordinator.isSillVirtualDisplay(number.uint32Value) else { return nil }
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        if !windows.isEmpty { onCovered?() }
    }

    /// Each built-in display at brightness 0, its own level kept the first time.
    private func dim() {
        guard isUp, let get = Brightness.get, let set = Brightness.set else { return }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return }
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            if brightness[id] == nil {
                var level: Float = 0
                if get(id, &level) == 0 { brightness[id] = level }
            }
            _ = set(id, 0)
        }
    }
}

/// The built-in display's brightness, through the private DisplayServices framework; nil where it is
/// missing (nothing is dimmed, the black windows still cover).
private enum Brightness {
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    static let get: Get? = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    static let set: Set? = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
}

/// The tap and the thread its run loop runs on: an event of the Mac's own waits for nothing on the
/// main thread, and a device's waits only for the marker's check.
private final class CurtainTap {
    private let port: CFMachPort
    private let thread: Thread
    private var loop: CFRunLoop?
    /// The callback's, held here for as long as the tap lives.
    private let box = TapBox()

    /// Nil when macOS refuses the tap (no Accessibility).
    init?() {
        let box = self.box
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CurtainPolicy.mask, callback: curtainTapCallback,
                                           userInfo: Unmanaged.passUnretained(box).toOpaque()) else { return nil }
        box.port = port
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        var started: CFRunLoop?
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        thread = Thread {
            started = CFRunLoopGetCurrent()
            CFRunLoopAddSource(started, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Sill curtain tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        loop = started
    }

    func stop() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
    }
}

/// The port, for the callback to turn the tap on again when macOS turns it off.
private final class TapBox {
    var port: CFMachPort?
}

private func curtainTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon, let port = Unmanaged<TapBox>.fromOpaque(refcon).takeUnretainedValue().port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    let user = event.getIntegerValueField(.eventSourceUserData)
    return CurtainPolicy.blocks(type: type.rawValue, userData: user) ? nil : Unmanaged.passUnretained(event)
}
