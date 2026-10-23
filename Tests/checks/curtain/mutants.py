"""Mutants of the curtain check: each changes one file it compiles in one place, and must make the check
fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "Curtain.swift": "Sources/StreamProtocol/Curtain.swift",
    "Switcher.swift": "Sources/StreamProtocol/Switcher.swift",
    "CurtainPolicy.swift": "Sources/SillHost/Curtain/CurtainPolicy.swift",
}
MUTANTS = [
    ("the kind at 55", "StreamMessage.swift", "case curtain = 52", "case curtain = 55"),
    ("the problem word", "Curtain.swift", 'public static let accessibility = "accessibility"', 'public static let accessibility = "access"'),
    ("the list's curtain dropped", "Switcher.swift", "        self.curtain = curtain\n", ""),
    ("Sill's own stopped", "CurtainPolicy.swift", "userData != marker && blocked.contains(type)", "blocked.contains(type)"),
    ("nothing stopped", "CurtainPolicy.swift", "userData != marker && blocked.contains(type)", "userData == marker && blocked.contains(type)"),
    ("everything stopped", "CurtainPolicy.swift", "userData != marker && blocked.contains(type)", "userData != marker"),
    ("another mark", "CurtainPolicy.swift", "static let marker: Int64 = 0x5111_C0DE", "static let marker: Int64 = 0x5111_C0DF"),
    ("the system keys pass", "CurtainPolicy.swift", "        14,                           // system keys", "        // system keys"),
    ("the modifiers pass", "CurtainPolicy.swift", "10, 11, 12,", "10, 11,"),
    ("the pointer's moves pass", "CurtainPolicy.swift", "1, 2, 3, 4, 5, 6, 7,", "1, 2, 3, 4, 6, 7,"),
    ("scrolls pass", "CurtainPolicy.swift", "22, 23, 24,", "23, 24,"),
    ("gestures pass", "CurtainPolicy.swift", "29, 30, 31, 32, 33, 34,", "32, 33, 34,"),
    ("the other buttons pass", "CurtainPolicy.swift", "25, 26, 27,", "27,"),
    ("an empty mask", "CurtainPolicy.swift", "$0 | (CGEventMask(1) << CGEventMask($1))", "$0 | (CGEventMask(0) << CGEventMask($1))"),
    ("the mask off by one", "CurtainPolicy.swift", "$0 | (CGEventMask(1) << CGEventMask($1))", "$0 | (CGEventMask(1) << CGEventMask($1 + 1))"),
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
