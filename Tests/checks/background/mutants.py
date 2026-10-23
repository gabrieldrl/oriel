"""Mutants of the background check: each changes one file it compiles in one place, and must make the check
fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "RemoteTLS.swift": "Sources/StreamProtocol/RemoteTLS.swift",
    "BackgroundPolicy.swift": "Sources/SillHost/Background/BackgroundPolicy.swift",
}
MUTANTS = [
    ("the leave at 58", "StreamMessage.swift", "case linkLeave = 57", "case linkLeave = 59"),
    ("not offered", "RemoteTLS.swift", "[sessionALPN, pairingALPN, backgroundALPN]", "[sessionALPN, pairingALPN]"),
    ("a rejected token forgiven", "BackgroundPolicy.swift", "let rejected = old?.pushRejected == true && old?.push?.token == join.push?.token",
     "let rejected = false"),
    ("a new token still rejected", "BackgroundPolicy.swift", "old?.push?.token == join.push?.token", "true"),
    ("heard rejoins", "BackgroundPolicy.swift", "out[device]?.heardAt = now", "out[device]?.heardAt = now; out[device]?.joinedAt = now"),
    ("never forgotten", "BackgroundPolicy.swift", "registry.filter { now - $0.value.heardAt < expiry }", "registry"),
    ("pushed without wanting", "BackgroundPolicy.swift", "$0.features.agentsNotify == true && $0.push != nil", "$0.push != nil"),
    ("pushed after a rejection", "BackgroundPolicy.swift", "$0.push != nil && $0.pushRejected != true", "$0.push != nil"),
    ("always watching", "BackgroundPolicy.swift", "registry.values.contains { $0.features.agentsNotify == true }", "!registry.isEmpty"),
    ("no key said nothing", "BackgroundPolicy.swift", "} else if !hasKey { problem = LinkState.noKey }", "}"),
    ("410 kept", "BackgroundPolicy.swift", "case 410: return .dropToken", "case 410: return .lost"),
    ("another app's token kept", "BackgroundPolicy.swift", '|| reason == "DeviceTokenNotForTopic"', ""),
    ("production to the sandbox", "BackgroundPolicy.swift", 'environment == PushTarget.production ? "api.push.apple.com"', 'environment == "never" ? "api.push.apple.com"'),
    ("a fraction in iat", "BackgroundPolicy.swift", '"iat":\\#(Int(issuedAt))', '"iat":\\#(issuedAt)'),
    ("padding kept", "BackgroundPolicy.swift", '.replacingOccurrences(of: "=", with: "")', ""),
    ("any file a key", "BackgroundPolicy.swift", 'guard fileName.hasPrefix("AuthKey_"), fileName.hasSuffix(".p8") else { return nil }', ""),
    ("the subtitle lost", "BackgroundPolicy.swift", 'if !subtitle.isEmpty { alert["subtitle"] = subtitle }', ""),
    ("one thread for every Mac", "BackgroundPolicy.swift", '"thread-id": macID ?? macName', '"thread-id": "sill"'),
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
