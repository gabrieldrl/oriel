"""Mutants of the displays check: each changes one file it compiles in one place, and must make the
check fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "Switcher.swift": "Sources/StreamProtocol/Switcher.swift",
    "Displays.swift": "Sources/StreamProtocol/Displays.swift",
    "DisplayPolicy.swift": "Sources/SillHost/Displays/DisplayPolicy.swift",
}
MUTANTS = [
    ("the list at 60", "StreamMessage.swift", "case displays = 49", "case displays = 60"),
    ("the control at 61", "StreamMessage.swift", "case displayControl = 50", "case displayControl = 61"),
    ("the picture at 62", "StreamMessage.swift", "case displayThumbnail = 51", "case displayThumbnail = 62"),
    ("showing counted on a window", "Switcher.swift", "if active == .desktop, let showing { return .display(showing) }", "if let showing { return .display(showing) }"),
    ("showing ignored", "Switcher.swift", "if active == .desktop, let showing { return .display(showing) }", "if active == .none, let showing { return .display(showing) }"),
    ("the grace at 20 s", "Displays.swift", "public static let grace: Double = 30", "public static let grace: Double = 20"),
    ("the add word", "Displays.swift", 'public static let add = "add"', 'public static let add = "new"'),
    ("the resize word", "Displays.swift", 'public static let resize = "resize"', 'public static let resize = "size"'),
    ("the match word", "Displays.swift", 'public static let primary = "primary"', 'public static let primary = "main"'),
    ("the end word", "Displays.swift", 'public static let end = "end"', 'public static let end = "disconnect"'),
    ("a display listed as itself", "DisplayPolicy.swift", "if case .display(let id) = self { return (.desktop, id) }", "if case .display(let id) = self { return (self, id) }"),
    ("a window takes the Desktop's menus", "DisplayPolicy.swift", "case .none, .window: return false", "case .none: return false\n        case .window: return true"),
    ("FNV's prime", "DisplayPolicy.swift", "&* 0x0100_0193", "&* 0x0100_0197"),
    ("the slot not in the id", "DisplayPolicy.swift", "return device << 8 | UInt32(slot & 0xFF)", "return device << 8"),
    ("a device part of 0", "DisplayPolicy.swift", "let device = (hash >> 8) == 0 ? 1 : hash >> 8", "let device = hash >> 8"),
    ("the low bits", "DisplayPolicy.swift", "let device = (hash >> 8) == 0 ? 1 : hash >> 8", "let device = (hash & 0xFFFFFF) == 0 ? 1 : hash & 0xFFFFFF"),
    ("the stage's product", "DisplayPolicy.swift", "static let productID: UInt32 = 0x0002", "static let productID: UInt32 = 0x0001"),
    ("five a device", "DisplayPolicy.swift", "static let maxPerDevice = 4", "static let maxPerDevice = 5"),
    ("slot 0 first", "DisplayPolicy.swift", "(1...maxPerDevice).first { !used.contains($0) }", "(0...maxPerDevice).first { !used.contains($0) }"),
    ("the names from 1", "DisplayPolicy.swift", "$0 < slot }.count + 2)", "$0 < slot }.count + 1)"),
    ("the gaps kept", "DisplayPolicy.swift", "Set(slots).filter { $0 < slot }.count + 2", "slot + 1"),
    ("the slot itself counted", "DisplayPolicy.swift", "Set(slots).filter { $0 < slot }.count", "Set(slots).filter { $0 <= slot }.count"),
    ("a repeat counted", "DisplayPolicy.swift", "Set(slots).filter { $0 < slot }.count", "slots.filter { $0 < slot }.count"),
    ("an empty key kept", "DisplayPolicy.swift", "if let fingerprint, !fingerprint.isEmpty {", "if let fingerprint {"),
    ("odd sides", "DisplayPolicy.swift", "sides.upperBound) & ~1", "sides.upperBound)"),
    ("no lower bound", "DisplayPolicy.swift", "min(max(v, sides.lowerBound), sides.upperBound)", "min(v, sides.upperBound)"),
    ("a negative width taken", "DisplayPolicy.swift", "width > 0, height > 0 else", "height > 0 else"),
    ("Disconnect waits", "DisplayPolicy.swift", "ending == .lost ? DisplayList.grace : 0", "ending == .removed ? 0 : DisplayList.grace"),
    ("a removed display keeps its windows", "DisplayPolicy.swift", "static func keepsWindows(_ ending: Ending) -> Bool { ending != .removed }", "static func keepsWindows(_ ending: Ending) -> Bool { true }"),
    ("on it by its corner", "DisplayPolicy.swift", "display.contains(CGPoint(x: window.midX, y: window.midY))", "display.contains(window.origin)"),
    ("unseen falls stay", "DisplayPolicy.swift", "guard let fell = k.fellTo else { return true }", "guard let fell = k.fellTo else { return false }"),
    ("a closed window returns", "DisplayPolicy.swift", "guard let now else { return false }", "guard let now else { return true }"),
    ("a resize ignored", "DisplayPolicy.swift", "&& abs(now.width - fell.width) <= tolerance && abs(now.height - fell.height) <= tolerance", "&& abs(now.height - fell.height) <= tolerance"),
    ("a wider tolerance", "DisplayPolicy.swift", "static let tolerance: CGFloat = 2", "static let tolerance: CGFloat = 3"),
    ("never kept on the display", "DisplayPolicy.swift", "y: min(max(y, bounds.minY), bounds.maxY - reachY))", "y: y)"),
    ("above the top", "DisplayPolicy.swift", "y: min(max(y, bounds.minY), bounds.maxY - reachY))", "y: min(y, bounds.maxY - reachY))"),
    ("the whole width off the right", "DisplayPolicy.swift", "bounds.maxX - reachX),", "bounds.maxX),"),
    ("1× never", "DisplayPolicy.swift", "/ width >= 1.5 ? 2 : 1 }", "/ width >= 0.5 ? 2 : 1 }"),
    ("always 2×", "DisplayPolicy.swift", "scale: primary.scale == 2 ? nil : primary.scale)", "scale: nil)"),
    ("a match not kept", "DisplayPolicy.swift", "height: s.height, matchesPrimary: true,", "height: s.height, matchesPrimary: nil,"),
    ("the match word ignored", "DisplayPolicy.swift", "if control.match == DisplayControl.primary { return matching(slot: slot, primary) }", "if control.match != nil { return matching(slot: slot, primary) }"),
    ("a size unclamped", "DisplayPolicy.swift", "let s = size(width: control.width, height: control.height)\n        return Memory.Slot(slot: slot, width: s.width, height: s.height)", "return Memory.Slot(slot: slot, width: control.width ?? 0, height: control.height ?? 0)"),
    ("brought back as saved", "DisplayPolicy.swift", "slot.matchesPrimary == true ? matching(slot: slot.slot, primary) : slot", "slot"),
    ("a false match matches", "DisplayPolicy.swift", "slot.matchesPrimary == true ? matching(slot: slot.slot, primary) : slot", "slot.matchesPrimary != nil ? matching(slot: slot.slot, primary) : slot"),
    ("the offset forgotten", "DisplayPolicy.swift", "let x = bounds.minX + k.offset.x, y = bounds.minY + k.offset.y", "let x = bounds.minX, y = bounds.minY + k.offset.y"),
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
