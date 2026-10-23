import Foundation

/// The Mac's sound on the device (kinds 47 and 48; docs/mac-sound-plan.md). Every control is the
/// device's: the host has no setting for it, and does what its devices ask.
///
/// - A host whose window list says `sound` 1 or more sends it. A device subscribes with any kind 48
///   (`{}` at connect) and is then sent kind 47, the sound, and kind 48, the Mac's volume and mute,
///   now and after every change (the Mac's own keys included).
/// - A device's kind 48 also sets the Mac's: `muted` true mutes the Mac's output and stops the sound
///   (nothing plays anywhere); false unmutes it, and the sound plays on the device, never on the
///   Mac's speakers while a device listens. `volume` (0…1) is the Mac's output volume, which the
///   device applies to what it plays.
/// - `onMac` (generation 2): true, the device does not take the sound, and while no device takes it
///   the Mac's own speakers play it; the device still sets the Mac's volume and mute. Sent only to a
///   host whose window list says `sound` 2 or more; the host answers it in every report to that device.
///
/// HostSettings.swift's rules apply: JSON, every field optional and left out when nil, fields
/// added later optional. Upstream's beta uses kinds 43 and 44 for its own audio and keyframe
/// request; these numbers are clear of every number its open work claims (33 to 46).
public struct SoundControl: Codable, Hashable, Sendable {
    /// The Mac's output volume, 0…1 (its volume slider's scale).
    public var volume: Double?
    /// The Mac's output muted (and nothing sent).
    public var muted: Bool?
    /// Host → device: why the Mac sends no sound although it is unmuted ("unsupported": before macOS
    /// 14.2; "failed": macOS refused the tap). Nil while it sends.
    public var problem: String?
    /// Device → host: increasing per device process; host → device: the newest token of that
    /// device's it has applied (`answering`), so a device ignores a report older than its own last
    /// change while its slider moves.
    public var token: Int?
    public var answering: Int?
    /// The sound plays on the Mac's speakers, not on this device (generation 2).
    public var onMac: Bool?

    public init(volume: Double? = nil, muted: Bool? = nil, problem: String? = nil,
                token: Int? = nil, answering: Int? = nil, onMac: Bool? = nil) {
        self.volume = volume; self.muted = muted; self.problem = problem
        self.token = token; self.answering = answering; self.onMac = onMac
    }

    /// The first generation: AAC-ELD, stereo (`WindowList.sound` 1 or more).
    public static let generation = 1
    /// A host that takes `onMac` says `sound` 2 or more.
    public static let playsOnMac = 2
}

/// Kind 47's first byte.
public enum SoundMessageType: UInt8, Sendable {
    /// JSON SoundFormat: what the packets that follow are, before an epoch's first packets.
    case format = 1
    /// SoundPackets, binary.
    case packets = 2
}

/// How an epoch's packets are encoded. A new epoch (a new tap or encoder) sends a new format.
public struct SoundFormat: Codable, Hashable, Sendable {
    /// "aac-eld".
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    public var framesPerPacket: Int
    /// The encoder's magic cookie (its AudioSpecificConfig), which the decoder needs.
    public var cookie: Data
    public var epoch: Int

    public init(codec: String = "aac-eld", sampleRate: Double, channels: Int, framesPerPacket: Int,
                cookie: Data, epoch: Int) {
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.framesPerPacket = framesPerPacket; self.cookie = cookie; self.epoch = epoch
    }
}

/// A run of encoded packets: `epoch UInt16 · seq UInt32 · flags UInt8 · count UInt8 · count ×
/// (length UInt16 · bytes)`, big endian. `seq` is the first packet's; the rest follow it. The
/// message header's timestamp is the host's clock as the first packet's first sample was heard.
public struct SoundPackets: Hashable, Sendable {
    public var epoch: UInt16
    public var seq: UInt32
    /// Bit 0: the first packet starts a segment (after silence, or the first of an epoch): the
    /// device fills its buffer again before it plays.
    public var flags: UInt8
    public var packets: [Data]

    public static let segmentStart: UInt8 = 1
    /// At most this many packets in one message, and this many bytes in one packet.
    public static let maxPackets = 16
    public static let maxPacketBytes = 4096

    public init(epoch: UInt16, seq: UInt32, flags: UInt8, packets: [Data]) {
        self.epoch = epoch; self.seq = seq; self.flags = flags; self.packets = packets
    }

    public var startsSegment: Bool { flags & Self.segmentStart != 0 }

    /// Kind 47's payload, its type byte first.
    public func encoded() -> Data {
        var d = Data(capacity: 9 + packets.reduce(0) { $0 + 2 + $1.count })
        d.append(SoundMessageType.packets.rawValue)
        d.append(UInt8(epoch >> 8)); d.append(UInt8(epoch & 0xFF))
        for shift in stride(from: 24, through: 0, by: -8) { d.append(UInt8((seq >> UInt32(shift)) & 0xFF)) }
        d.append(flags)
        d.append(UInt8(packets.count))
        for p in packets {
            d.append(UInt8(p.count >> 8)); d.append(UInt8(p.count & 0xFF))
            d.append(p)
        }
        return d
    }

    /// The packets of a kind 47 payload whose type byte says packets; nil for anything malformed.
    public static func parse(_ payload: Data) -> SoundPackets? {
        let b = [UInt8](payload)
        guard b.count >= 9, b[0] == SoundMessageType.packets.rawValue else { return nil }
        let epoch = UInt16(b[1]) << 8 | UInt16(b[2])
        let seq = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
        let flags = b[7]
        let count = Int(b[8])
        guard count >= 1, count <= maxPackets else { return nil }
        var packets: [Data] = []
        packets.reserveCapacity(count)
        var i = 9
        for _ in 0..<count {
            guard i + 2 <= b.count else { return nil }
            let n = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard n >= 1, n <= maxPacketBytes, i + n <= b.count else { return nil }
            packets.append(Data(b[i..<(i + n)]))
            i += n
        }
        guard i == b.count else { return nil }
        return SoundPackets(epoch: epoch, seq: seq, flags: flags, packets: packets)
    }

    /// Kind 47's payload for a format.
    public static func formatPayload(_ format: SoundFormat) -> Data {
        var d = Data([SoundMessageType.format.rawValue])
        d.append((try? JSONEncoder().encode(format)) ?? Data())
        return d
    }

    /// The format of a kind 47 payload whose type byte says format.
    public static func parseFormat(_ payload: Data) -> SoundFormat? {
        guard payload.count > 1, payload.first == SoundMessageType.format.rawValue else { return nil }
        return try? JSONDecoder().decode(SoundFormat.self, from: payload.dropFirst())
    }
}
