"""Mutants of the display-settings check: each changes iOSClient/DisplaySettingsMemory.swift in one place,
and must make the check fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
FILE = os.path.join(WT, "iOSClient/DisplaySettingsMemory.swift")
MUTANTS = [
    ("Primary renamed", 'static let primary = "Primary"', 'static let primary = "Desktop"'),
    ("away shared", "return away ? name + awaySuffix : name", "return name"),
    ("away the other way", "return away ? name + awaySuffix : name", "return away ? name : name + awaySuffix"),
    ("by name", "name = displayKey(id)", "name = displays.first { $0.id == id }!.name"),
    ("the key's word", '"display \\(id)"', '"Display \\(id)"'),
    ("an unlisted display taken", "guard displays.contains(where: { $0.id == id }) else { return nil }", ""),
    ("an unlisted display as Primary", "guard displays.contains(where: { $0.id == id }) else { return nil }", "guard displays.contains(where: { $0.id == id }) else { return away ? primary + awaySuffix : primary }"),
    ("a window as Primary", "case .none, .window: return nil", "case .none: return nil\n        case .window: name = primary"),
    ("a first show sends", "guard let saved else { return (nil, DisplaySettings(shown)) }", "guard let saved else { return (HostSettingsChange(captureScale: shown.captureScale), DisplaySettings(shown)) }"),
    ("a first show keeps nothing new", "guard let saved else { return (nil, DisplaySettings(shown)) }", "guard let saved else { return (nil, DisplaySettings(captureScale: 1, maxFPS: 60, bitrate: 15_000_000)) }"),
    ("the scale always sent", "if saved.captureScale != shown.captureScale, SettingsChoices", "if SettingsChoices"),
    ("any scale sent", "if saved.captureScale != shown.captureScale, SettingsChoices.captureScale.contains(saved.captureScale) {", "if saved.captureScale != shown.captureScale {"),
    ("the rate never sent", "change.maxFPS = saved.maxFPS }", "}"),
    ("any rate sent", "if saved.maxFPS != shown.maxFPS, SettingsChoices.maxFPS.contains(saved.maxFPS)", "if saved.maxFPS != shown.maxFPS"),
    ("a custom bitrate sent", "if saved.bitrate != shown.bitrate, SettingsChoices.bitrate.contains(saved.bitrate)", "if saved.bitrate != shown.bitrate"),
    ("the quality never sent", "{ change.bitrate = saved.bitrate }", "{ }"),
    ("an empty change sent", "return (change.isEmpty ? nil : change, saved)", "return (change, saved)"),
    ("a return keeps what is shown", "return (change.isEmpty ? nil : change, saved)", "return (change.isEmpty ? nil : change, DisplaySettings(shown))"),
    ("a pick forgets the rest", "var s = saved ?? DisplaySettings(shown)", "var s = DisplaySettings(shown)"),
    ("a scale pick lost", "if let v = change.captureScale { s.captureScale = v }", ""),
    ("a rate pick lost", "if let v = change.maxFPS { s.maxFPS = v }", ""),
    ("a quality pick lost", "if let v = change.bitrate { s.bitrate = v }", ""),
    ("the rate kept as the quality", "if let v = change.bitrate { s.bitrate = v }", "if let v = change.bitrate { s.maxFPS = v / 1_000_000 }"),
]
caught = 0
text = open(FILE).read()
for name, old, new in MUTANTS:
    if text.count(old) != 1:
        print(f"NOT APPLIED {name}: pattern found {text.count(old)} times"); continue
    with tempfile.TemporaryDirectory() as t:
        path = os.path.join(t, "DisplaySettingsMemory.swift")
        open(path, "w").write(text.replace(old, new))
        exe = os.path.join(t, "check")
        b = subprocess.run([os.path.join(HERE, "build.sh"), WT, exe, path], capture_output=True, text=True)
        if not os.path.exists(exe):
            print(f"DOES NOT COMPILE {name}\n{(b.stdout + b.stderr)[:600]}"); continue
        r = subprocess.run([exe], capture_output=True, text=True, timeout=300)
        failed = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        ok = r.returncode != 0 and bool(failed)
        caught += ok
        print(f"{'caught' if ok else 'MISSED'} {name}: {len(failed)} failing, e.g. {[f[:90] for f in failed[:2]]}")
print(f"{caught} of {len(MUTANTS)} mutants caught")
