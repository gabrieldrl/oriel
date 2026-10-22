import AVFoundation
import AudioToolbox
import os
import StreamProtocol
import UIKit

/// The Mac's sound, played (kind 47; docs/mac-sound-plan.md). StreamClient hands it every kind 47
/// from its network queue; it decodes on its own queue into a ring that an AVAudioSourceNode reads.
///
/// - A format starts an epoch: a new decoder; packets of another epoch are dropped.
/// - A segment (after silence, the start of an epoch, a gap in the packets) plays only once
///   `target` is buffered: 40 ms at home, 120 ms away, raised 10 ms (to 200) by every underrun
///   within a segment. Above the target by 60 ms the ring gives up one frame a render, so it never
///   drifts behind; past 250 ms it skips to the target.
/// - The gain is the Mac's volume (the tap hears the Mac's processes before its volume), on a cubic
///   curve, ramped across each render so a slider move never clicks.
/// - The engine runs while there is something to play: it starts at the first packets and stops
///   after 20 s with none (the Mac sends none during silence), on mute, in the background and with
///   the session.
///
/// The session is `.playback` with `.mixWithOthers`: Sill's sound plays beside other apps', and the
/// Ring/Silent switch does not mute it (the person mutes with Sill's pill).
final class SoundPlayer: @unchecked Sendable {
    static let homeTarget = 0.040
    static let awayTarget = 0.120
    static let maxTarget = 0.200
    static let idleStop: TimeInterval = 20

    private let queue = DispatchQueue(label: "sill.sound.play", qos: .userInteractive)
    // On `queue`:
    private var decoder: SoundDecoder?
    private var epoch: Int?
    private var nextSeq: UInt32?
    private var scratch = [Float](repeating: 0, count: 4096 * 2)
    private var away = false

    private let ring = PlayRing(capacityFrames: 48_000)
    // On the main thread:
    private var engine: AVAudioEngine?
    private var engineRate: Double = 0
    private var allowed = true
    private var idleTimer: Timer?
    private var lastHeard: TimeInterval = 0

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopEngine(why: "in the background")
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.stopEngine(why: "interrupted")
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine = nil
        }
    }

    // MARK: The Mac's sound (the network queue)

    /// A kind 47 payload. `away`: the session is through the remote door (a larger buffer).
    func receive(_ payload: Data, away: Bool) {
        guard let type = payload.first else { return }
        if type == SoundMessageType.format.rawValue {
            guard let format = SoundPackets.parseFormat(payload) else { return }
            queue.async { self.begin(format, away: away) }
        } else if type == SoundMessageType.packets.rawValue {
            guard let packets = SoundPackets.parse(payload) else { return }
            queue.async { self.play(packets) }
        }
    }

    /// The session ended, or the Mac muted: nothing kept.
    func reset() {
        queue.async {
            self.decoder = nil
            self.epoch = nil
            self.nextSeq = nil
            self.ring.clear()
        }
        DispatchQueue.main.async { self.stopEngine(why: nil) }
    }

    /// The Mac's volume, 0…1, as the device shows it.
    func setVolume(_ volume: Double) {
        let v = Float(min(max(volume, 0), 1))
        ring.setGain(v * v * v)
    }

    /// Whether the engine may run (unmuted).
    func setAllowed(_ on: Bool) {
        DispatchQueue.main.async {
            self.allowed = on
            if !on { self.stopEngine(why: "muted") }
        }
    }

    // MARK: Decoding (on `queue`)

    private func begin(_ format: SoundFormat, away: Bool) {
        guard format.codec == "aac-eld", format.channels == 2, format.sampleRate >= 8_000, format.sampleRate <= 96_000,
              format.framesPerPacket > 0, format.framesPerPacket <= 4096 else {
            #if DEBUG
            print("sound: a format this build does not play: \(format.codec), \(format.channels) ch")
            #endif
            decoder = nil; epoch = nil
            return
        }
        do {
            decoder = try SoundDecoder(format: format)
        } catch {
            #if DEBUG
            print("sound: the decoder could not be made: \(error)")
            #endif
            decoder = nil; epoch = nil
            return
        }
        epoch = format.epoch
        nextSeq = nil
        self.away = away
        ring.clear()
        ring.configure(rate: format.sampleRate, target: away ? Self.awayTarget : Self.homeTarget)
        #if DEBUG
        print("sound: epoch \(format.epoch), AAC-ELD \(Int(format.sampleRate)) Hz, \(format.framesPerPacket) frames a packet, "
              + "buffer \(Int((away ? Self.awayTarget : Self.homeTarget) * 1000)) ms")
        #endif
        let rate = format.sampleRate
        DispatchQueue.main.async { self.prepareEngine(rate: rate) }
    }

    private func play(_ packets: SoundPackets) {
        guard let decoder, let epoch, Int(packets.epoch) == epoch else { return }
        // A segment begins after silence, at an epoch's first packets, and wherever packets went
        // missing (a remote queue that was too full): the decoder starts afresh and the ring fills.
        let gap = nextSeq.map { $0 != packets.seq } ?? true
        if packets.startsSegment || gap {
            decoder.reset()
            ring.startSegment(continuing: !packets.startsSegment)
        }
        nextSeq = packets.seq &+ UInt32(packets.packets.count)
        for packet in packets.packets {
            let frames = scratch.withUnsafeMutableBufferPointer { decoder.decode(packet, into: $0.baseAddress!, capacity: $0.count / 2) }
            if frames > 0 { scratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) } }
        }
        DispatchQueue.main.async { self.heard() }
    }

    // MARK: The engine (main thread)

    private func prepareEngine(rate: Double) {
        if engine != nil, engineRate != rate { stopEngine(why: "a new rate") }
        engineRate = rate
    }

    /// Packets came: the engine runs (if it may), and its idle clock starts again.
    private func heard() {
        guard allowed, UIApplication.shared.applicationState != .background, engineRate > 0 else { return }
        lastHeard = ProcessInfo.processInfo.systemUptime
        guard engine == nil else { return }
        startEngine()
        guard engine != nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, ProcessInfo.processInfo.systemUptime - self.lastHeard > Self.idleStop else { return }
            self.stopEngine(why: "\(Int(Self.idleStop)) s without sound")
        }
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("sound: the audio session would not start: \(error)")
            #endif
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: engineRate, channels: 2) else { return }
        let engine = AVAudioEngine()
        let ring = ring
        let source = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.render(left: left, right: right, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            #if DEBUG
            print("sound: the engine would not start: \(error)")
            #endif
            return
        }
        self.engine = engine
        ring.engineStarted()
        #if DEBUG
        print("sound: playing (IO buffer \(Int(session.ioBufferDuration * 1000)) ms, output latency \(Int(session.outputLatency * 1000)) ms)")
        #endif
    }

    private func stopEngine(why: String?) {
        idleTimer?.invalidate()
        idleTimer = nil
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ring.startSegment(continuing: false)
        #if DEBUG
        if let why { print("sound: stopped (\(why))") }
        #endif
    }
}

/// Decoded frames, interleaved stereo, written by the player's queue and read by the render thread;
/// a lock held for a copy, on both sides. It keeps the buffering rule (SoundPlayer's).
final class PlayRing: @unchecked Sendable {
    private struct State {
        var read = 0
        var count = 0
        var rate: Double = 48_000
        var target = 1920
        var maxTarget = 9600
        var buffering = true
        /// The ring ran dry within a segment: the next packet of it raises the target.
        var underran = false
        /// Frames still to render before a dry ring counts: an engine's first callbacks come
        /// unevenly as it starts.
        var settling = 0
        var gain: Float = 0
        var playedGain: Float = 0
    }
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(capacityFrames: Int) {
        capacity = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { samples.deallocate() }

    func configure(rate: Double, target: TimeInterval) {
        lock.withLockUnchecked {
            $0.rate = rate
            $0.target = Int(target * rate)
            $0.maxTarget = Int(SoundPlayer.maxTarget * rate)
        }
    }

    func setGain(_ gain: Float) { lock.withLockUnchecked { $0.gain = gain } }

    /// The engine has started: half a second before running dry raises the target.
    func engineStarted() { lock.withLockUnchecked { $0.settling = Int(0.5 * $0.rate) } }

    func clear() {
        lock.withLockUnchecked { $0.read = 0; $0.count = 0; $0.buffering = true; $0.underran = false }
    }

    /// A segment begins: it plays once the target is buffered, unless what is left of the last one
    /// covers it. `continuing`: packets went missing within one, so an underrun since counts.
    func startSegment(continuing: Bool) {
        lock.withLockUnchecked {
            if $0.count < $0.target { $0.buffering = true }
            if !continuing { $0.underran = false }
        }
    }

    /// Interleaved frames, after the oldest when full.
    func write(_ source: UnsafePointer<Float>, frames: Int) {
        lock.withLockUnchecked { s in
            if s.underran {
                s.underran = false
                s.target = min(s.target + Int(0.010 * s.rate), s.maxTarget)
                #if DEBUG
                print("sound: ran dry; buffering \(Int(Double(s.target) / s.rate * 1000)) ms now")
                #endif
            }
            var frames = frames
            var source = source
            if frames > capacity { source += (frames - capacity) * 2; frames = capacity }
            let overflow = s.count + frames - capacity
            if overflow > 0 { s.read = (s.read + overflow) % capacity; s.count -= overflow }
            var at = (s.read + s.count) % capacity
            var left = frames
            while left > 0 {
                let n = min(left, capacity - at)
                (samples + at * 2).update(from: source, count: n * 2)
                source += n * 2; left -= n; at = (at + n) % capacity
            }
            s.count += frames
        }
    }

    /// The render thread's `frames` of each channel, at the gain.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLockUnchecked { s in
            if s.buffering {
                if s.count >= s.target { s.buffering = false }
                else { silence(left, right, frames); return }
            }
            // Behind: past 250 ms, to the target at once; 60 ms over, a frame a render.
            if s.count > s.target + Int(0.250 * s.rate) {
                let skip = s.count - s.target
                s.read = (s.read + skip) % capacity; s.count -= skip
            } else if s.count > s.target + Int(0.060 * s.rate) + frames {
                s.read = (s.read + 1) % capacity; s.count -= 1
            }
            let n = min(frames, s.count)
            let from = s.playedGain, to = s.gain
            let step = n > 0 ? (to - from) / Float(n) : 0
            var g = from
            var at = s.read
            for i in 0..<n {
                g += step
                left[i] = samples[at * 2] * g
                right[i] = samples[at * 2 + 1] * g
                at += 1
                if at == capacity { at = 0 }
            }
            s.read = at; s.count -= n
            s.playedGain = n > 0 ? to : s.playedGain
            if n < frames {
                for i in n..<frames { left[i] = 0; right[i] = 0 }
                s.buffering = true
                if s.settling == 0 { s.underran = true }
            }
            s.settling = max(0, s.settling - frames)
        }
    }

    private func silence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
    }
}

/// AAC-ELD packets to interleaved stereo Float32 at the format's rate (AudioToolbox), one packet a
/// call. Only the player's queue calls it.
final class SoundDecoder {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        let step: String
        var description: String { "\(step) failed (\(status))" }
    }

    private let converter: AudioConverterRef
    private let framesPerPacket: Int
    private let feed = Feed()

    init(format: SoundFormat) throws {
        var input = AudioStreamBasicDescription()
        input.mFormatID = kAudioFormatMPEG4AAC_ELD
        input.mSampleRate = format.sampleRate
        input.mChannelsPerFrame = UInt32(format.channels)
        input.mFramesPerPacket = UInt32(format.framesPerPacket)
        var output = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        var status = AudioConverterNew(&input, &output, &made)
        guard status == noErr, let converter = made else { throw Failure(status: status, step: "the AAC-ELD decoder") }
        if !format.cookie.isEmpty {
            status = format.cookie.withUnsafeBytes {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
            }
            guard status == noErr else { AudioConverterDispose(converter); throw Failure(status: status, step: "the magic cookie") }
        }
        self.converter = converter
        framesPerPacket = format.framesPerPacket
    }

    deinit { AudioConverterDispose(converter) }

    /// Forgets what came before (a new segment).
    func reset() { AudioConverterReset(converter) }

    /// One packet into `out` (interleaved, room for `capacity` frames); the frames written.
    func decode(_ packet: Data, into out: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
        packet.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return 0 }
            feed.bytes = base
            feed.count = bytes.count
            feed.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(bytes.count))
            defer { feed.bytes = nil; feed.count = 0 }
            var frames = UInt32(min(framesPerPacket, capacity))
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: frames * 8, mData: out))
            let status = AudioConverterFillComplexBuffer(converter, Self.supply, Unmanaged.passUnretained(feed).toOpaque(),
                                                         &frames, &list, nil)
            guard status == noErr || status == Self.noMoreInput else { return 0 }
            return Int(frames)
        }
    }

    private static let noMoreInput: OSStatus = 0x6E6F_6D6F   // 'nomo'

    private final class Feed {
        var bytes: UnsafeRawPointer?
        var count = 0
        /// The packet's description, at an address that outlives the input proc's call.
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        init() { description.initialize(to: AudioStreamPacketDescription()) }
        deinit { description.deallocate() }
    }

    private static let supply: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, context in
        let feed = Unmanaged<Feed>.fromOpaque(context!).takeUnretainedValue()
        guard let bytes = feed.bytes, feed.count > 0 else {
            packets.pointee = 0
            return SoundDecoder.noMoreInput
        }
        packets.pointee = 1
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = 2
        data.pointee.mBuffers.mDataByteSize = UInt32(feed.count)
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: bytes)
        descriptions?.pointee = feed.description
        feed.count = 0   // given: the next call is told there is no more
        return noErr
    }
}
