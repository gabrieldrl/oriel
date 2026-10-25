"""Mutants of the desktops check: each changes one file it compiles in one place, and must make the
check fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "Switcher.swift": "Sources/StreamProtocol/Switcher.swift",
    "Desktops.swift": "Sources/StreamProtocol/Desktops.swift",
    "DesktopPolicy.swift": "Sources/SillHost/Desktops/DesktopPolicy.swift",
}
MUTANTS = [
    ("the list at 60", "StreamMessage.swift", "case desktops = 53", "case desktops = 60"),
    ("the control at 61", "StreamMessage.swift", "case desktopControl = 54", "case desktopControl = 61"),
    ("the picture at 62", "StreamMessage.swift", "case desktopThumbnail = 55", "case desktopThumbnail = 62"),
    ("the window list's key", "Switcher.swift", "self.curtain = curtain; self.desktops = desktops", "self.curtain = curtain; self.desktops = nil"),
    ("generation 2", "Desktops.swift", "public static let generation = 1\n    /// `display` for", "public static let generation = 2\n    /// `display` for"),
    ("the Mac's display at 1", "Desktops.swift", "public static let macDisplay: UInt32 = 0", "public static let macDisplay: UInt32 = 1"),
    ("a set by the wrong field", "Desktops.swift", "displays.first { $0.display == display }", "displays.first { $0.display != display }"),
    ("the picture's id little-endian", "Desktops.swift", "d.appendBigEndian(spaceID)", "d.appendBigEndian(spaceID.byteSwapped)"),
    ("an empty picture taken", "Desktops.swift", "guard d.count > 8 else { return nil }", "guard d.count >= 8 else { return nil }"),
    ("the picture from the slice's base", "Desktops.swift", "d.subdata(in: (d.startIndex + 8)..<d.endIndex)", "d.subdata(in: 8..<d.count)"),
    ("the desktop type at 1", "DesktopPolicy.swift", "package static let desktopType = 0", "package static let desktopType = 1"),
    ("the full-screen type at 5", "DesktopPolicy.swift", "package static let fullScreenType = 4", "package static let fullScreenType = 5"),
    ("every type kept", "DesktopPolicy.swift", "type == desktopType || type == fullScreenType else { return nil }", "true else { return nil }"),
    ("a desktop's pid kept", "DesktopPolicy.swift", "pid: type == fullScreenType ? (s[\"pid\"] as? NSNumber)?.int32Value : nil)", "pid: (s[\"pid\"] as? NSNumber)?.int32Value)"),
    ("full screen read as a desktop", "DesktopPolicy.swift", "return Space(id: id, fullScreen: type == fullScreenType,", "return Space(id: id, fullScreen: false,"),
    ("full-screen apps counted", "DesktopPolicy.swift", "                return MacDesktop(id: s.id, name: app, app: app)\n", "                n += 1\n                return MacDesktop(id: s.id, name: app, app: app)\n"),
    ("numbered from 0", "DesktopPolicy.swift", "            n += 1\n            return MacDesktop(id: s.id, name: \"Desktop \\(n)\")", "            defer { n += 1 }\n            return MacDesktop(id: s.id, name: \"Desktop \\(n)\")"),
    ("no app named", "DesktopPolicy.swift", "let app = s.pid.flatMap(appName) ?? \"Full Screen\"", "let app = \"Full Screen\""),
    ("the shared set's name", "DesktopPolicy.swift", "package static let sharedUUID = \"Main\"", "package static let sharedUUID = \"main\""),
    ("the main UUID first", "DesktopPolicy.swift", "sets.first(where: { $0.uuid == sharedUUID }) ?? sets.first(where: { mainUUID != nil && $0.uuid == mainUUID })", "sets.first(where: { mainUUID != nil && $0.uuid == mainUUID }) ?? sets.first(where: { $0.uuid == sharedUUID })"),
    ("any set the Mac's own", "DesktopPolicy.swift", "sets.first(where: { mainUUID != nil && $0.uuid == mainUUID })", "sets.first"),
    ("16 steps too few", "DesktopPolicy.swift", "package static let maxSteps = 16", "package static let maxSteps = 15"),
    ("the timeout", "DesktopPolicy.swift", "package static let stepTimeout: Double = 1.5", "package static let stepTimeout: Double = 1"),
    ("already there steps", "DesktopPolicy.swift", "guard let current, current != target,", "guard let current,"),
    ("the limit out by one", "DesktopPolicy.swift", "guard count <= maxSteps else { return nil }", "guard count < maxSteps else { return nil }"),
    ("the direction turned", "DesktopPolicy.swift", "return (to > from ? .right : .left, count)", "return (to > from ? .left : .right, count)"),
    ("one step always", "DesktopPolicy.swift", "return (to > from ? .right : .left, count)", "return (to > from ? .right : .left, 1)"),
    ("a picture across a switch", "DesktopPolicy.swift", "guard let before, before == after else { return nil }", "guard let before else { return nil }"),
    ("the Mac's own last", "DesktopPolicy.swift", "let order = [DesktopControl.macDisplay] + owned", "let order = owned + [DesktopControl.macDisplay]"),
    ("the current space dropped", "DesktopPolicy.swift", "DesktopSet(display: id, current: s.current, desktops:", "DesktopSet(display: id, current: nil, desktops:"),
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
