"""Mutants of the version-match check: each changes VersionMatch.swift in one place, and must make the
check fail. usage: mutants.py WORKTREE"""
import glob, os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
FILE = os.path.join(WT, "Sources/StreamProtocol/VersionMatch.swift")
OTHERS = [p for p in sorted(glob.glob(os.path.join(WT, "Sources/StreamProtocol/*.swift"))) if p != FILE]
MUTANTS = [
    ("the same never", "if mac == device { return .same }", "if mac != device { return .same }"),
    ("the sides swapped", "return mac < device ? .updateMac : .updateDevice", "return mac < device ? .updateDevice : .updateMac"),
    ("always the device", "return mac < device ? .updateMac : .updateDevice", "return .updateDevice"),
    ("a missing Mac version read as 0", "guard let mac = mac.flatMap({ SillVersion($0) })", "guard let mac = Optional(mac ?? \"0\").flatMap({ SillVersion($0) })"),
    ("the device's notice names the wrong one", 'case .updateDevice: return "Update Oriel on this \\(deviceWord): \\(name) has \\(shown(mac))."', 'case .updateDevice: return "Update Oriel on \\(name): this \\(deviceWord) has \\(shown(mac))."'),
    ("the device's notice the wrong version", 'case .updateMac: return "Update Oriel on \\(name): this \\(deviceWord) has \\(shown(device))."', 'case .updateMac: return "Update Oriel on \\(name): this \\(deviceWord) has \\(shown(mac))."'),
    ("no Mac name, empty", 'let name = macName.isEmpty ? "the Mac" : macName', "let name = macName"),
    ("the Mac's line the wrong version", 'case .updateDevice: return "Update Oriel on it to \\(shown(mac))"', 'case .updateDevice: return "Update Oriel on it to \\(shown(device))"'),
    ("the Mac's line when the same", "case .same, .unknown: return nil\n        }\n    }\n\n    /// A version", 'case .same: return ""\n        case .unknown: return nil\n        }\n    }\n\n    /// A version'),
    ("shown as typed", "text.flatMap { SillVersion($0) }?.description ?? \"\"", "text ?? \"\""),
]
caught = 0
text = open(FILE).read()
for name, old, new in MUTANTS:
    if text.count(old) != 1:
        print(f"NOT APPLIED {name}: pattern found {text.count(old)} times"); continue
    with tempfile.TemporaryDirectory() as t:
        path = os.path.join(t, "VersionMatch.swift")
        open(path, "w").write(text.replace(old, new))
        exe = os.path.join(t, "check")
        b = subprocess.run(["swiftc", "-O", *OTHERS, path, os.path.join(HERE, "main.swift"), "-o", exe], capture_output=True, text=True)
        if not os.path.exists(exe):
            print(f"DOES NOT COMPILE {name}\n{(b.stdout + b.stderr)[:600]}"); continue
        r = subprocess.run([exe], capture_output=True, text=True, timeout=300)
        failed = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0 and bool(failed)
        caught += ok
        print(f"{'caught' if ok else 'MISSED'} {name}: {len(failed)} failing, e.g. {[f[:90] for f in failed[:2]]}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
