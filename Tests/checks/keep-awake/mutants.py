"""Mutants of the keep-awake check: each changes one file it compiles in one place, and must make the
check fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "Switcher.swift": "Sources/StreamProtocol/Switcher.swift",
    "KeepAwake.swift": "Sources/StreamProtocol/KeepAwake.swift",
    "KeepAwakePolicy.swift": "Sources/SillHost/KeepAwake/KeepAwakePolicy.swift",
}
MUTANTS = [
    ("the kind at 60", "StreamMessage.swift", "case keepAwake = 56", "case keepAwake = 60"),
    ("the list's keepAwake dropped", "Switcher.swift", "self.desktops = desktops; self.keepAwake = keepAwake", "self.desktops = desktops"),
    ("the approval word", "KeepAwake.swift", 'public static let approval = "approval"', 'public static let approval = "login"'),
    ("a mode renamed on the wire", "KeepAwake.swift", "    case plugged\n", "    case plugged = \"pluggedIn\"\n"),
    ("Off holds", "KeepAwakePolicy.swift", "case .off: return false", "case .off: return true"),
    ("When Plugged In ignores the adapter", "KeepAwakePolicy.swift", "case .plugged: return onPower", "case .plugged: return true"),
    ("held without the helper", "KeepAwakePolicy.swift", "wants(mode, onPower: onPower) && helper == .enabled", "wants(mode, onPower: onPower)"),
    ("Off registers", "KeepAwakePolicy.swift", "mode != .off && (helper == .notRegistered", "(helper == .notRegistered"),
    ("registered again", "KeepAwakePolicy.swift", "(helper == .notRegistered || helper == .notFound)", "helper != .unavailable"),
    ("approval never said", "KeepAwakePolicy.swift", "case .requiresApproval, .notRegistered, .notFound: return KeepAwake.approval", "case .requiresApproval, .notRegistered, .notFound: return nil"),
    ("a problem while nothing is wanted", "KeepAwakePolicy.swift", "guard wants(mode, onPower: onPower) else { return nil }", ""),
    ("awake whatever the mode", "KeepAwakePolicy.swift", "awake: held && hold(mode, onPower: onPower, helper: helper)", "awake: held"),
    ("the line on a desktop", "KeepAwakePolicy.swift", "mode == .always && battery }", "mode == .always }"),
    ("When Plugged In on a desktop", "KeepAwakePolicy.swift", "battery ? [.off, .always, .plugged] : [.off, .always]", "[.off, .always, .plugged]"),
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
