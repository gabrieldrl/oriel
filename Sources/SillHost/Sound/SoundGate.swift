import Foundation
import StreamProtocol

/// Which packets of the Mac's sound go out, and how they are grouped into messages
/// (docs/mac-sound-plan.md). Pure: the pipeline feeds it each packet's peak and hands it the
/// encoded packet; `Tests/checks/sound` checks it.
///
/// - Silence is not sent: a packet whose peak is under `threshold` (−90 dBFS) after `hangover`
///   quiet packets (200 ms, the tail of a sound and the encoder's look-ahead) ends the segment. The
///   next loud packet starts one, which the device fills its buffer for before it plays.
/// - Two packets a message (20 ms), so half as many messages as packets; a segment's last packets
///   go out at its end, alone if need be.
struct SoundGate {
    /// −90 dBFS.
    static let threshold: Float = 3.1623e-5
    /// Quiet packets still sent after the last loud one.
    static let hangover = 20
    static let packetsPerMessage = 2

    enum Verdict: Equatable {
        /// Encode this packet; `startsSegment` for the first after silence.
        case send(startsSegment: Bool)
        /// Not encoded; `endsSegment` once, as the gate closes (flush what waits).
        case skip(endsSegment: Bool)
    }

    private(set) var open = false
    private var quiet = 0

    /// The verdict for the next packet, by its peak (the largest absolute sample).
    mutating func judge(peak: Float) -> Verdict {
        if peak >= Self.threshold {
            quiet = 0
            if open { return .send(startsSegment: false) }
            open = true
            return .send(startsSegment: true)
        }
        guard open else { return .skip(endsSegment: false) }
        quiet += 1
        if quiet <= Self.hangover { return .send(startsSegment: false) }
        open = false
        quiet = 0
        return .skip(endsSegment: true)
    }

    /// Forgets the segment: the next loud packet starts one (a new epoch, a device subscribing).
    mutating func reset() { open = false; quiet = 0 }
}

/// Packets waiting to go out together: the first one's sequence number, flags and capture time.
/// Only the first packet's start counts, so the caller takes what waits before a segment's first
/// packet (SoundPipeline's flush).
struct SoundBatch {
    private(set) var packets: [Data] = []
    private(set) var firstSeq: UInt32 = 0
    private(set) var flags: UInt8 = 0
    private(set) var time: Double = 0

    var isEmpty: Bool { packets.isEmpty }

    /// Adds one; true when the message is full.
    mutating func add(_ packet: Data, seq: UInt32, startsSegment: Bool, time: Double) -> Bool {
        if packets.isEmpty {
            firstSeq = seq
            flags = startsSegment ? SoundPackets.segmentStart : 0
            self.time = time
        }
        packets.append(packet)
        return packets.count >= SoundGate.packetsPerMessage
    }

    /// What waits, as one message's packets, and empties the batch; nil when nothing waits.
    mutating func take(epoch: UInt16) -> (packets: SoundPackets, time: Double)? {
        guard !packets.isEmpty else { return nil }
        let out = SoundPackets(epoch: epoch, seq: firstSeq, flags: flags, packets: packets)
        packets.removeAll(keepingCapacity: true)
        return (out, time)
    }
}
