import Foundation
import Network
import os
import StreamProtocol

/// The Mac's sound, the host's side (kinds 47 and 48; docs/mac-sound-plan.md). Every control is the
/// devices': this keeps who listens and does what they ask.
///
/// - A device subscribes with any kind 48 (`{}` at connect); one line ("Sound: iPad (iPad14,1) plays
///   this Mac's sound."). It is sent the format, then the packets, and kind 48 with the Mac's volume
///   and mute now and after every change, the Mac's own keys included.
/// - While one listens and the Mac is not muted, the tap reads every process's sound but Sill's, and
///   the Mac's speakers stay silent (SystemAudioTap). Muted (a device's mute, or the Mac's own),
///   the tap goes and nothing is sent: nothing plays anywhere. The last device leaving takes the tap
///   with it, and the Mac plays again at the volume and mute last set.
/// - A device's `volume` sets the Mac's output volume, which the device applies to what it plays (the
///   tap hears the processes before it).
/// - A synthetic host never taps this Mac: a test tone (TestTone), and a volume and mute of its own.
///
/// No line per volume change. Stats: `snd.sent` (messages), `snd.dropped` (a remote queue too full).
@MainActor
final class HostSound {
    /// The window lists' `sound`.
    var advertised: Int? { SoundControl.generation }

    private let server: StreamServer
    private let synthetic: Bool
    private let mac: MacVolume?
    /// A synthetic host's own volume and mute.
    private var testState = MacVolume.State(volume: 0.5, muted: false)
    private struct Subscriber {
        let connection: NWConnection
        let who: String
        var answering: Int?
    }
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    /// The connections the pipeline sends to, read on its queue.
    private let listeners = OSAllocatedUnfairLock<[ObjectIdentifier]>(initialState: [])
    private let pipeline = SoundPipeline()
    private var tap: AnyObject?
    private var tone: TestTone?
    private var problem: String?
    private var capturing = false

    init(server: StreamServer, synthetic: Bool) {
        self.server = server
        self.synthetic = synthetic
        mac = synthetic ? nil : MacVolume()
        let listeners = listeners
        pipeline.onFormat = { [server] format in
            server.sendSound(Self.formatMessage(format), to: listeners.withLock { $0 })
        }
        pipeline.onPackets = { [server] packets, time in
            let message = StreamMessage(kind: .sound, timestamp: time, isKeyframe: false, payload: packets.encoded())
            server.sendSound(message.serialized(), to: listeners.withLock { $0 })
        }
        mac?.onChange = { [weak self] _ in self?.stateChanged() }
        mac?.onDeviceChange = { [weak self] in self?.outputDeviceChanged() }
    }

    private var state: MacVolume.State { mac?.state ?? testState }

    // MARK: A device's message

    /// A kind 48 from `connection`, named `who` for the lines.
    func received(_ payload: Data, from connection: NWConnection, who: String) {
        guard let control = Wire.decode(SoundControl.self, from: payload) else { return }
        let id = ObjectIdentifier(connection)
        if subscribers[id] == nil { subscribe(connection, who: who) }
        if let token = control.token { subscribers[id]?.answering = token }
        let before = state
        if let muted = control.muted, muted != state.muted {
            print("Sound: \(muted ? "muted" : "unmuted") from \(who).")
            if let mac { mac.setMuted(muted) } else { testState.muted = muted; stateChanged() }
        }
        if let volume = control.volume, volume.isFinite {
            if let mac { mac.setVolume(volume) } else { testState.volume = min(max(volume, 0), 1); stateChanged() }
        }
        updateCapture()
        // A change was told to every device (stateChanged), this one's token with it; otherwise this
        // device alone hears the state, its token back.
        if state == before { sendState(to: [id]) }
    }

    /// The device left: forgotten without a line; the last one takes the tap with it.
    func clientLeft(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard subscribers.removeValue(forKey: id) != nil else { return }
        listeners.withLock { $0.removeAll { $0 == id } }
        updateCapture()
    }

    /// The host is quitting: the tap goes, so the Mac's speakers play again.
    func stop() {
        subscribers = [:]
        listeners.withLock { $0 = [] }
        updateCapture()
    }

    private func subscribe(_ connection: NWConnection, who: String) {
        let id = ObjectIdentifier(connection)
        subscribers[id] = Subscriber(connection: connection, who: who)
        print("Sound: \(who) plays this Mac's sound.")
        if subscribers.count == 1 { mac?.start() }
        // The format first, then the packets: both go through the server's queue in this order.
        if let format = pipeline.format { server.sendSound(Self.formatMessage(format), to: [id]) }
        listeners.withLock { $0.append(id) }
        pipeline.markSegment()
    }

    // MARK: The capture

    private func updateCapture() {
        let want = !subscribers.isEmpty && !state.muted
        guard want != capturing else { return }
        if want { startCapture() } else { stopCapture() }
    }

    private func startCapture() {
        capturing = true
        let before = problem
        problem = nil
        if synthetic {
            do {
                try pipeline.start(inputRate: TestTone.rate)
                let t = TestTone(pipeline: pipeline)
                t.start()
                tone = t
                print("Sound: a test tone (a test host never taps this Mac's sound).")
            } catch {
                problem = "failed"
                print("Sound: the test tone could not start: \(error).")
            }
        } else if #available(macOS 14.2, *) {
            do {
                let t = try SystemAudioTap(pipeline: pipeline, outputUID: mac?.deviceUID)
                tap = t
                let kHz = (t.sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
                let n = subscribers.count
                print("Sound: this Mac's sound goes to \(n) device\(n == 1 ? "" : "s") at \(kHz) kHz; its own speakers are silent meanwhile.")
            } catch {
                problem = "failed"
                print("Sound: macOS did not let Sill hear this Mac's sound: \(error). The Mac's speakers play as usual.")
            }
        } else {
            problem = "unsupported"
            print("Sound: sending this Mac's sound needs macOS 14.2 or later.")
        }
        if problem != before { sendState(to: Array(subscribers.keys)) }
    }

    private func stopCapture() {
        capturing = false
        tone?.stop(); tone = nil
        if #available(macOS 14.2, *), let t = tap as? SystemAudioTap {
            t.stop()
            print(subscribers.isEmpty ? "Sound: no device listens; this Mac's speakers play again."
                                      : "Sound: muted; nothing plays.")
        }
        tap = nil
        pipeline.stop()
    }

    /// Headphones plugged in, AirPlay picked: the tap's clock is the old device, so it is made again.
    private func outputDeviceChanged() {
        guard capturing, !synthetic else { return }
        stopCapture()
        updateCapture()
    }

    // MARK: Reports

    private func stateChanged() {
        updateCapture()
        sendState(to: Array(subscribers.keys))
    }

    private func sendState(to ids: [ObjectIdentifier]) {
        let s = state
        let messages: [(NWConnection, StreamMessage)] = ids.compactMap { id in
            guard let sub = subscribers[id] else { return nil }
            let control = SoundControl(volume: (s.volume * 1000).rounded() / 1000, muted: s.muted,
                                       problem: problem, answering: sub.answering)
            return (sub.connection, StreamMessage(kind: .soundControl, timestamp: Date().timeIntervalSince1970,
                                                  isKeyframe: false, payload: Wire.encode(control)))
        }
        server.send(each: messages)
    }

    nonisolated private static func formatMessage(_ format: SoundFormat) -> Data {
        StreamMessage(kind: .sound, timestamp: Date().timeIntervalSince1970, isKeyframe: false,
                      payload: SoundPackets.formatPayload(format)).serialized()
    }
}
