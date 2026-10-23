"""Mutants of the sound check: each changes one file it compiles in one place, and must make the
check fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "Sound.swift": "Sources/StreamProtocol/Sound.swift",
    "SoundGate.swift": "Sources/SillHost/Sound/SoundGate.swift",
}
MUTANTS = [
    ("the sound at 46", "StreamMessage.swift", "case sound = 47", "case sound = 46"),
    ("the control at 29", "StreamMessage.swift", "case soundControl = 48", "case soundControl = 29"),
    ("the epoch little endian", "Sound.swift", "d.append(UInt8(epoch >> 8)); d.append(UInt8(epoch & 0xFF))", "d.append(UInt8(epoch & 0xFF)); d.append(UInt8(epoch >> 8))"),
    ("a seq byte lost", "Sound.swift", "| UInt32(b[5]) << 8 | UInt32(b[6])", "| UInt32(b[5]) << 8"),
    ("17 packets taken", "Sound.swift", "guard count >= 1, count <= maxPackets else { return nil }", "guard count >= 1, count <= maxPackets + 1 else { return nil }"),
    ("no packets taken", "Sound.swift", "guard count >= 1, count <= maxPackets else { return nil }", "guard count <= maxPackets else { return nil }"),
    ("an empty packet taken", "Sound.swift", "guard n >= 1, n <= maxPacketBytes, i + n <= b.count else { return nil }", "guard n <= maxPacketBytes, i + n <= b.count else { return nil }"),
    ("trailing bytes taken", "Sound.swift", "guard i == b.count else { return nil }", "_ = i"),
    ("the type byte not read", "Sound.swift", "guard b.count >= 9, b[0] == SoundMessageType.packets.rawValue else { return nil }", "guard b.count >= 9 else { return nil }"),
    ("the start flag any bit", "Sound.swift", "flags & Self.segmentStart != 0", "flags != 0"),
    ("Play on Mac at generation 1", "Sound.swift", "public static let playsOnMac = 2", "public static let playsOnMac = 1"),
    ("onMac never kept", "Sound.swift", "self.answering = answering; self.onMac = onMac", "self.answering = answering"),
    ("the threshold at -80 dBFS", "SoundGate.swift", "static let threshold: Float = 3.1623e-5", "static let threshold: Float = 1e-4"),
    ("the threshold itself silence", "SoundGate.swift", "if peak >= Self.threshold {", "if peak > Self.threshold {"),
    ("a hangover one short", "SoundGate.swift", "if quiet <= Self.hangover { return .send(startsSegment: false) }", "if quiet < Self.hangover { return .send(startsSegment: false) }"),
    ("a loud packet not ending the quiet", "SoundGate.swift", "            quiet = 0\n            if open", "            if open"),
    ("no segment end", "SoundGate.swift", "return .skip(endsSegment: true)", "return .skip(endsSegment: false)"),
    ("reset keeping the segment", "SoundGate.swift", "mutating func reset() { open = false; quiet = 0 }", "mutating func reset() { quiet = 0 }"),
    ("three packets a message", "SoundGate.swift", "static let packetsPerMessage = 2", "static let packetsPerMessage = 3"),
    ("the last packet's flags", "SoundGate.swift", "        if packets.isEmpty {\n            firstSeq = seq\n            flags = startsSegment ? SoundPackets.segmentStart : 0",
     "        flags = startsSegment ? SoundPackets.segmentStart : 0\n        if packets.isEmpty {\n            firstSeq = seq"),
    ("the last packet's time", "SoundGate.swift", "            self.time = time\n        }", "        }\n        self.time = time"),
]
caught = 0
for name, file, old, new in MUTANTS:
    text = open(os.path.join(WT, PATHS[file])).read()
    if text.count(old) != 1:
        print(f"NOT APPLIED {name}: pattern found {text.count(old)} times"); continue
    with tempfile.TemporaryDirectory() as t:
        path = os.path.join(t, file)
        open(path, "w").write(text.replace(old, new))
        exe = os.path.join(t, "check")
        b = subprocess.run([os.path.join(HERE, "build.sh"), WT, exe, f"{file}={path}"], capture_output=True, text=True)
        if not os.path.exists(exe):
            print(f"DOES NOT COMPILE {name}\n{(b.stdout + b.stderr)[:600]}"); continue
        r = subprocess.run([exe], capture_output=True, text=True, timeout=300)
        failed = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0 and bool(failed)
        caught += ok
        print(f"{'caught' if ok else 'MISSED'} {name}: {len(failed)} failing, e.g. {[f[:90] for f in failed[:2]]}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
sys.exit(0 if caught == len(MUTANTS) else 1)
