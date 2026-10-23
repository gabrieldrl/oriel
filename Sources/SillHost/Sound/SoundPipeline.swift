import AudioToolbox
import CoreAudio
import Foundation
import os
import StreamProtocol

/// The Mac's sound from its capture to kind 47 (docs/mac-sound-plan.md): a source (the Mac's tap,
/// or a synthetic host's tone) writes into `ring` from its own thread; the queue `sill.sound` reads
/// whole packets out, lets SoundGate decide, encodes, groups two a message and hands each message
/// to `send`. Nothing is allocated per packet but the packet's own bytes.
///
/// Threading: `push` from the source's thread (Core Audio's IO thread: a lock held for a copy, a
/// signal that never allocates); everything else on `queue`. `start` and `stop` from anywhere.
final class SoundPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "sill.sound", qos: .userInteractive)

    /// On `queue`: a format before an epoch's first packets, and each message's packets with the
    /// time its first sample was heard.
    var onFormat: ((SoundFormat) -> Void)?
    var onPackets: ((SoundPackets, Double) -> Void)?

    private let ring = SoundRing(capacityFrames: 96_000)
    private var signal: DispatchSourceUserDataAdd?
    // On `queue`:
    private var encoder: SoundEncoder?
    private var chunk: [Float] = []
    private var gate = SoundGate()
    private var batch = SoundBatch()
    private var seq: UInt32 = 0
    /// The next packet out starts a segment: set where the gate opens, cleared by the packet that
    /// carries it (the encoder may hold that one back, its look-ahead).
    private var pendingStart = false
    private var epoch: UInt16 = 0
    private(set) var format: SoundFormat?

    /// Begins an epoch at the capture's rate: a new encoder, its format sent. Throws when the
    /// encoder cannot be made.
    func start(inputRate: Double) throws {
        let encoder = try SoundEncoder(inputRate: inputRate)
        queue.sync {
            self.encoder = encoder
            chunk = [Float](repeating: 0, count: encoder.inputFramesPerPacket * SoundEncoder.channels)
            ring.reset()
            gate.reset()
            batch = SoundBatch()
            pendingStart = false
            epoch &+= 1
            seq = 0
            let f = SoundFormat(sampleRate: encoder.sampleRate, channels: SoundEncoder.channels,
                                framesPerPacket: encoder.framesPerPacket, cookie: encoder.cookie, epoch: Int(epoch))
            format = f
            onFormat?(f)
            if signal == nil {
                let s = DispatchSource.makeUserDataAddSource(queue: queue)
                s.setEventHandler { [weak self] in self?.drain() }
                s.resume()
                signal = s
            }
        }
    }

    /// Ends the epoch: what waits goes out, the encoder goes.
    func stop() {
        queue.sync {
            flush()
            encoder = nil
            format = nil
            ring.reset()
        }
    }

    /// The next device subscribed: its first packets start a segment, so it fills its buffer.
    func markSegment() { queue.async { [self] in gate.reset() } }

    /// Interleaved stereo frames. Any thread; never blocks for long, never allocates.
    func push(interleaved samples: UnsafePointer<Float>, frames: Int) {
        ring.write(interleaved: samples, frames: frames)
        signal?.add(data: 1)
    }

    /// Planar (one buffer a channel) frames; one channel is played on both.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        ring.write(left: left, right: right ?? left, frames: frames)
        signal?.add(data: 1)
    }

    private func drain() {
        guard let encoder else { return }
        let frames = encoder.inputFramesPerPacket
        let n = frames * SoundEncoder.channels
        while ring.available >= frames {
            chunk.withUnsafeMutableBufferPointer { buf in
                ring.read(into: buf.baseAddress!, frames: frames)
            }
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(chunk[i])) }
            switch gate.judge(peak: peak) {
            case .skip(let ends):
                if ends { flush() }
            case .send(let starts):
                // A segment's first packet leads its message: what waits (a device subscribing
                // mid-message reset the gate) goes out first.
                if starts { flush(); pendingStart = true }
                let now = Date().timeIntervalSince1970 - Double(ring.available + frames) / encoder.inputRate
                chunk.withUnsafeBufferPointer { buf in
                    encoder.encode(buf.baseAddress!) { bytes in
                        guard bytes.count <= SoundPackets.maxPacketBytes else { return }
                        let full = batch.add(Data(bytes), seq: seq, startsSegment: pendingStart, time: now)
                        pendingStart = false
                        seq &+= 1
                        if full { flush() }
                    }
                }
            }
        }
    }

    private func flush() {
        if let m = batch.take(epoch: epoch) { onPackets?(m.packets, m.time) }
    }
}

/// Interleaved stereo frames, written by the capture and read by the pipeline. A full ring drops
/// its oldest frames (the reader stalled). A lock held for a copy, on both sides.
final class SoundRing: @unchecked Sendable {
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private var start = 0          // frames
    private var count = 0          // frames
    private let lock = OSAllocatedUnfairLock()

    init(capacityFrames: Int) {
        capacity = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0, count: capacityFrames * 2)
    }
    deinit { samples.deallocate() }

    var available: Int { lock.withLockUnchecked { count } }

    func reset() { lock.withLockUnchecked { start = 0; count = 0 } }

    func write(interleaved src: UnsafePointer<Float>, frames: Int) {
        lock.withLockUnchecked {
            for f in 0..<frames {
                let at = slotForWrite()
                samples[at * 2] = src[f * 2]
                samples[at * 2 + 1] = src[f * 2 + 1]
            }
        }
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        lock.withLockUnchecked {
            for f in 0..<frames {
                let at = slotForWrite()
                samples[at * 2] = left[f]
                samples[at * 2 + 1] = right[f]
            }
        }
    }

    /// Under the lock: the slot for one more frame, the oldest dropped when full.
    private func slotForWrite() -> Int {
        if count == capacity { start = (start + 1) % capacity; count -= 1 }
        let at = (start + count) % capacity
        count += 1
        return at
    }

    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLockUnchecked {
            let n = min(frames, count)
            for f in 0..<n {
                let at = (start + f) % capacity
                dst[f * 2] = samples[at * 2]
                dst[f * 2 + 1] = samples[at * 2 + 1]
            }
            start = (start + n) % capacity
            count -= n
        }
    }
}

/// A synthetic host's sound: a 440 Hz tone, 1 s on and 0.5 s off (so the gate's segments are
/// exercised), at 48 kHz. Never this Mac's sound: a test must not silence its speakers.
final class TestTone: @unchecked Sendable {
    private let pipeline: SoundPipeline
    private let queue = DispatchQueue(label: "sill.sound.tone", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var buffer = [Float](repeating: 0, count: 480 * 2)
    static let rate = 48_000.0

    init(pipeline: SoundPipeline) { self.pipeline = pipeline }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        for i in 0..<480 {
            let t = Double(frame + i)
            let on = (frame + i) % 72_000 < 48_000
            let v = on ? Float(0.2 * sin(2 * .pi * 440 * t / Self.rate)) : 0
            buffer[i * 2] = v
            buffer[i * 2 + 1] = v
        }
        frame += 480
        buffer.withUnsafeBufferPointer { pipeline.push(interleaved: $0.baseAddress!, frames: 480) }
    }
}

/// The Mac's sound: a Core Audio process tap of every process but Sill, muted while it is read
/// (`CATapMutedWhenTapped`: the Mac's speakers stay silent while Sill reads it, and play again the
/// moment it stops, also if Sill hangs or is killed), in a private aggregate device whose IO proc
/// pushes each buffer into the pipeline. macOS asks once for System Audio Recording ("Oriel would
/// like to record…"), and while it is refused the tap hears silence.
final class SystemAudioTap {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        let step: String
        var description: String { "\(step) failed (\(status))" }
    }

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let io = DispatchQueue(label: "sill.sound.tap", qos: .userInteractive)
    /// The aggregate device's rate, which the IO proc's buffers are at.
    let sampleRate: Double

    /// `outputUID`: the Mac's output device, the aggregate's clock (nil: none, the tap's own).
    init(pipeline: SoundPipeline, outputUID: String?) throws {
        let own = Self.processObject(pid: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.name = "Oriel"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure(status: status, step: "the Mac's sound tap") }
        self.tap = tap

        let sub: [String: Any] = [kAudioSubTapUIDKey: description.uuid.uuidString,
                                  kAudioSubTapDriftCompensationKey: true]
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oriel",
            kAudioAggregateDeviceUIDKey: "com.gabrieldrl.sill.sound." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [sub],
        ]
        if let outputUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(status: status, step: "the sound tap's device")
        }
        self.aggregate = aggregate

        var rate = Float64(48_000)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &rate) != noErr || rate <= 0 { rate = 48_000 }
        sampleRate = rate

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, io) { [weak pipeline] _, input, _, _, _ in
            guard let pipeline else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if list.count == 1, let data = list[0].mData {
                let b = list[0]
                let channels = Int(b.mNumberChannels)
                let frames = Int(b.mDataByteSize) / (4 * max(channels, 1))
                let p = data.assumingMemoryBound(to: Float.self)
                if channels == 2 { pipeline.push(interleaved: p, frames: frames) }
                else if channels == 1 { pipeline.push(left: p, right: nil, frames: frames) }
            } else if list.count >= 2, let l = list[0].mData, let r = list[1].mData {
                let frames = Int(list[0].mDataByteSize) / 4
                pipeline.push(left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self), frames: frames)
            }
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(status: status, step: "the sound tap's reader")
        }
        self.proc = proc
        try pipeline.start(inputRate: rate)
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            stop()
            throw Failure(status: status, step: "starting the sound tap")
        }
    }

    /// Stops reading and destroys the tap: the Mac's speakers play again. Idempotent.
    func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }

    deinit { stop() }

    /// This process's Core Audio object, which the tap leaves out; nil before Sill has made a sound.
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
