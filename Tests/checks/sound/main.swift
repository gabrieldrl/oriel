import Foundation

// The Mac's sound (docs/mac-sound-plan.md), against Sources/StreamProtocol and the host's
// SoundGate.swift compiled into this binary (build.sh). Kinds 47 and 48, SoundControl's JSON,
// SoundPackets both ways and what it refuses, SoundFormat, the silence gate and the batching; then a
// random model: a stream of peaks through the gate and the batch, against what the device must get.
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }

// MARK: - The kinds and the window list

func header(_ kind: UInt8) -> StreamHeader? {
    StreamMessage.parseHeader(Data([kind]) + Data(count: 9) + Data([0, 0, 0, 2]))
}
check(StreamMessageKind.sound.rawValue == 47 && StreamMessageKind(rawValue: 47) == .sound, "kind 47 is the sound")
check(StreamMessageKind.soundControl.rawValue == 48 && StreamMessageKind(rawValue: 48) == .soundControl, "kind 48 is its control")
check(header(47)?.kind == .sound && header(48)?.kind == .soundControl, "both headers parse")
check([29, 30, 31].allSatisfy { StreamMessageKind(rawValue: $0) == nil }, "29 to 31 stay free")
check(StreamMessageKind(rawValue: 32) == .clipboard, "32 is still the clipboard")
check(SoundControl.generation == 1, "this generation is 1")
check(SoundControl.playsOnMac == 2, "a host that takes onMac says 2")
check(json(SoundControl(onMac: true)) == #"{"onMac":true}"#, "on the Mac: \(json(SoundControl(onMac: true)))")
check(Wire.decode(SoundControl.self, from: Data(#"{"onMac":true,"answering":3}"#.utf8))?.onMac == true, "a report says it")
check(Wire.decode(SoundControl.self, from: Data(#"{"volume":0.5}"#.utf8))?.onMac == nil, "an older report says nothing")
let list = WindowList(macName: "Mac", windows: [], active: .desktop, sound: SoundControl.generation)
check(json(list).contains(#""sound":1"#), "a host that sends sound says sound 1: \(json(list))")
check(!json(WindowList(macName: "Mac", windows: [], active: .desktop)).contains("sound"), "one that does not leaves it out")
check(Wire.decode(WindowList.self, from: Data(json(list).utf8))?.sound == 1, "sound 1 reads back")

// MARK: - SoundControl

check(json(SoundControl()) == "{}", "the subscription is {}: \(json(SoundControl()))")
check(json(SoundControl(volume: 0.5, token: 3)) == #"{"token":3,"volume":0.5}"#, "a volume change: \(json(SoundControl(volume: 0.5, token: 3)))")
check(json(SoundControl(muted: true, token: 4)) == #"{"muted":true,"token":4}"#, "a mute")
let report = SoundControl(volume: 0.25, muted: false, problem: "failed", answering: 4)
check(Wire.decode(SoundControl.self, from: Wire.encode(report)) == report, "a report reads back whole")
check(Wire.decode(SoundControl.self, from: Data(#"{"volume":0.3,"later":[1,2]}"#.utf8))?.volume == 0.3, "a later field is skipped")
check(Wire.decode(SoundControl.self, from: Data("{}".utf8)) == SoundControl(), "{} reads as nothing set")

// MARK: - SoundPackets

func bytes(_ n: Int, _ v: UInt8) -> Data { Data(repeating: v, count: n) }
let p = SoundPackets(epoch: 0x1234, seq: 0xA1B2_C3D4, flags: SoundPackets.segmentStart, packets: [bytes(3, 7), bytes(300, 9)])
let e = p.encoded()
check(e.first == SoundMessageType.packets.rawValue, "packets begin with type 2")
check(Array(e.prefix(11)) == [2, 0x12, 0x34, 0xA1, 0xB2, 0xC3, 0xD4, 1, 2, 0, 3], "the header is big endian: \(Array(e.prefix(11)))")
check(e.count == 9 + 2 + 3 + 2 + 300, "the length: \(e.count)")
check(SoundPackets.parse(e) == p, "packets read back whole")
check(p.startsSegment && !SoundPackets(epoch: 1, seq: 0, flags: 2, packets: [bytes(1, 0)]).startsSegment, "bit 0 alone starts a segment")
let full = SoundPackets(epoch: 0xFFFF, seq: .max, flags: 0, packets: (0..<SoundPackets.maxPackets).map { _ in bytes(SoundPackets.maxPacketBytes, 1) })
check(SoundPackets.parse(full.encoded()) == full, "16 packets of 4096 bytes read back")
func withCount(_ c: Int) -> Data { var d = e; d[8] = UInt8(c); return d }
check(SoundPackets.parse(withCount(0)) == nil, "a count of 0 before packets refused")
check(SoundPackets.parse(Data([2, 0, 1, 0, 0, 0, 5, 0, 0])) == nil, "a message of no packets refused")
let over = SoundPackets(epoch: 1, seq: 1, flags: 0, packets: (0...SoundPackets.maxPackets).map { _ in bytes(1, 1) })
check(SoundPackets.parse(over.encoded()) == nil, "17 packets refused")
check(SoundPackets.parse(SoundPackets(epoch: 1, seq: 1, flags: 0, packets: [bytes(SoundPackets.maxPacketBytes + 1, 1)]).encoded()) == nil,
      "a 4097-byte packet refused")
check(SoundPackets.parse(SoundPackets(epoch: 1, seq: 1, flags: 0, packets: [Data()]).encoded()) == nil, "an empty packet refused")
check(SoundPackets.parse(e.dropLast()) == nil, "a cut packet refused")
check(SoundPackets.parse(e + Data([0])) == nil, "a trailing byte refused")
check(SoundPackets.parse(withCount(3)) == nil, "a count past the packets refused")
check(SoundPackets.parse(Data(e.prefix(8))) == nil, "a cut header refused")
var typed = e; typed[0] = 1
check(SoundPackets.parse(typed) == nil, "a format is no packets")
check(SoundPackets.parse(Data()) == nil, "nothing refused")
// Every cut and every single-byte change: never a crash; a parse that succeeds encodes back to it.
for n in 0..<e.count {
    let cut = Data(e.prefix(n))
    check(SoundPackets.parse(cut) == nil, "cut at \(n) refused")
}
var rng = SystemRandomNumberGenerator()
var flipsOK = true
for _ in 0..<5000 {
    var d = e
    d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
    if let q = SoundPackets.parse(d), q.encoded() != d { flipsOK = false }
}
check(flipsOK, "a changed payload that parses encodes back to itself")

// MARK: - SoundFormat

let format = SoundFormat(sampleRate: 48_000, channels: 2, framesPerPacket: 480, cookie: Data([0xF8, 0xE8, 0x50, 0x00]), epoch: 3)
let fp = SoundPackets.formatPayload(format)
check(fp.first == SoundMessageType.format.rawValue, "a format begins with type 1")
check(SoundPackets.parseFormat(fp) == format, "a format reads back")
check(SoundPackets.parseFormat(e) == nil && SoundPackets.parse(fp) == nil, "neither reads as the other")
check(SoundPackets.parseFormat(Data([1])) == nil && SoundPackets.parseFormat(Data()) == nil, "an empty format refused")
check(format.codec == "aac-eld", "the codec is AAC-ELD")
check(String(decoding: fp.dropFirst(), as: UTF8.self).contains(#""cookie":"+OhQAA==""#), "the cookie goes as base64")

// MARK: - The gate

let loud: Float = 0.1, quiet: Float = 0
check(SoundGate.threshold > 3.16e-5 && SoundGate.threshold < 3.17e-5, "the threshold is -90 dBFS")
var g = SoundGate()
check(g.judge(peak: quiet) == .skip(endsSegment: false), "silence from the start is skipped, no segment ends")
check(g.judge(peak: SoundGate.threshold) == .send(startsSegment: true), "the threshold itself is sound, and starts a segment")
check(g.judge(peak: loud) == .send(startsSegment: false), "the next loud packet goes on")
for i in 1...SoundGate.hangover { check(g.judge(peak: quiet) == .send(startsSegment: false), "quiet packet \(i) of the hangover sent") }
check(g.judge(peak: quiet) == .skip(endsSegment: true), "the 21st quiet packet ends the segment")
check(g.judge(peak: quiet) == .skip(endsSegment: false), "and the next is skipped without ending another")
check(g.judge(peak: SoundGate.threshold * 0.99) == .skip(endsSegment: false), "just under the threshold is silence")
check(g.judge(peak: loud) == .send(startsSegment: true), "sound again starts a new segment")
for _ in 1...10 { _ = g.judge(peak: quiet) }
check(g.judge(peak: loud) == .send(startsSegment: false), "a loud packet within the hangover keeps the segment")
for _ in 1...SoundGate.hangover { _ = g.judge(peak: quiet) }
check(g.judge(peak: loud) == .send(startsSegment: false), "a loud packet after exactly the hangover keeps it too")
g.reset()
check(g.judge(peak: loud) == .send(startsSegment: true), "after a reset the next loud packet starts one")

// MARK: - The batch

var b = SoundBatch()
check(b.isEmpty && b.take(epoch: 1) == nil, "an empty batch takes nothing")
check(!b.add(bytes(2, 1), seq: 10, startsSegment: true, time: 5), "one packet does not fill it")
check(b.add(bytes(2, 2), seq: 11, startsSegment: false, time: 6), "two do")
if let m = b.take(epoch: 7) {
    check(m.packets == SoundPackets(epoch: 7, seq: 10, flags: SoundPackets.segmentStart, packets: [bytes(2, 1), bytes(2, 2)]),
          "the message is the first packet's seq and flags, both packets: \(m.packets)")
    check(m.time == 5, "and the first packet's time")
} else { check(false, "two packets make a message") }
check(b.isEmpty && b.take(epoch: 7) == nil, "taking empties it")
_ = b.add(bytes(2, 3), seq: 12, startsSegment: false, time: 7)
check(b.take(epoch: 7)?.packets.flags == 0, "a batch that does not start a segment has no flag")
_ = b.add(bytes(2, 3), seq: 20, startsSegment: false, time: 8)
_ = b.add(bytes(2, 4), seq: 21, startsSegment: true, time: 9)
check(b.take(epoch: 7)?.packets.seq == 20, "a batch's seq is its first packet's")

// MARK: - A model: random peaks through the gate and the batch, as SoundPipeline drives them

// The pipeline: each packet judged; at a segment's start what waits is taken first; a sent packet is
// encoded (here, its seq's bytes), though the encoder may hold one back (its look-ahead), and the
// first one out after a start carries it; a full batch, or the gate closing, is taken. A device
// subscribing resets the gate at any point (markSegment). The device must see every packet out once,
// in order, seqs consecutive within a message, each segment start on the first packet out after the
// gate opened, and the first packet a segment start.
var modelOK = true
var modelNote = ""
for run in 0..<3000 {
    var gate = SoundGate(), batch = SoundBatch()
    var seq: UInt32 = 0
    var pendingStart = false
    var out: [(seq: UInt32, starts: Bool)] = []
    var got: [(seq: UInt32, starts: Bool)] = []
    func flush() {
        guard let m = batch.take(epoch: 1) else { return }
        guard let q = SoundPackets.parse(m.packets.encoded()) else { modelOK = false; modelNote = "run \(run): a message did not parse"; return }
        if m.time != Double(q.seq) { modelOK = false; modelNote = "run \(run): a message's time is not its first packet's" }
        for (i, pkt) in q.packets.enumerated() {
            let s = q.seq + UInt32(i)
            if pkt != Data(withUnsafeBytes(of: s.bigEndian) { Data($0) }) { modelOK = false; modelNote = "run \(run): seq \(s) out of place" }
            got.append((s, i == 0 && q.startsSegment))
        }
    }
    var silence = Bool.random(using: &rng)
    let holdBack = Int.random(in: 0...3, using: &rng)   // 0: never; else one in 4, 8, 12
    for _ in 0..<Int.random(in: 1...300, using: &rng) {
        if Int.random(in: 0..<12, using: &rng) == 0 { silence.toggle() }
        if Int.random(in: 0..<40, using: &rng) == 0 { gate.reset() }
        let peak: Float = silence ? (Bool.random(using: &rng) ? 0 : 1e-6) : Float.random(in: 1e-4...1, using: &rng)
        switch gate.judge(peak: peak) {
        case .send(let starts):
            if starts { flush(); pendingStart = true }
            if holdBack > 0, Int.random(in: 0..<(4 * holdBack), using: &rng) == 0 { break }
            out.append((seq, pendingStart))
            let full = batch.add(Data(withUnsafeBytes(of: seq.bigEndian) { Data($0) }), seq: seq, startsSegment: pendingStart, time: Double(seq))
            pendingStart = false
            seq += 1
            if full { flush() }
        case .skip(let ends):
            if ends { flush() }
        }
    }
    flush()
    if got.map(\.seq) != out.map(\.seq) { modelOK = false; modelNote = "run \(run): got \(got.count) of \(out.count) packets" }
    else if got.map(\.starts) != out.map(\.starts) { modelOK = false; modelNote = "run \(run): a segment start lost, moved or added" }
    if let first = got.first, !first.starts { modelOK = false; modelNote = "run \(run): the first packet starts no segment" }
}
check(modelOK, "the model: \(modelNote)")

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
