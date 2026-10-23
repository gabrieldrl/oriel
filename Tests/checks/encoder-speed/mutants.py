#!/usr/bin/env python3
# Each mutant changes Sources/SillHost/EncoderSpeedJudge.swift in one place (in a copy under
# .build/checks/encoder-speed/, never the file itself); the speed check (main.swift here)
# must fail on every one. Encoder-free: a mutant binary that links VideoToolbox is refused, not run.
# usage: Tests/checks/encoder-speed/mutants.py [path to EncoderSpeedJudge.swift]
#        (or Tests/checks/encoder-speed/run.sh --mutants)
import subprocess, sys, os
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, '..', '..', '..'))
src_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'Sources', 'SillHost', 'EncoderSpeedJudge.swift')
out = os.path.join(root, '.build', 'checks', 'encoder-speed')
src = open(src_path).read()
mutants = [
    ("behind without motion", "        Double(captures.count) >= Self.minInputFraction * Double(fps) * Self.window\n            && ", "        "),
    ("behind at any share kept", "            && Double(returns.count) < Self.keepUpFraction * Double(captures.count)\n", ""),
    ("90% kept counts as behind", "Double(returns.count) < Self.keepUpFraction * Double(captures.count)", "Double(returns.count) <= Self.keepUpFraction * Double(captures.count)"),
    ("behind with room in the budget", "            && median >= Self.budgetFraction * budget\n", "\n"),
    ("the budget at the whole frame's time", "median >= Self.budgetFraction * budget", "median >= budget"),
    ("no window for the evidence", "guard mayAct, pending == nil, now - since >= Self.window else { return nil }", "guard mayAct, pending == nil else { return nil }"),
    ("mayAct ignored", "guard mayAct, pending == nil, now - since >= Self.window else { return nil }", "guard pending == nil, now - since >= Self.window else { return nil }"),
    ("a second switch while one is pending", "guard mayAct, pending == nil, now - since >= Self.window else { return nil }", "guard mayAct, now - since >= Self.window else { return nil }"),
    ("too few frames back still a median", "let enough = returns.count >= Self.minReturns", "let enough = returns.count >= 1"),
    ("given up still switches", "guard !gaveUp, let median, behind(median: median) else { return nil }", "guard let median, behind(median: median) else { return nil }"),
    ("no faster at 95% only", "if median >= Self.noFasterFraction * quality {", "if median >= 0.95 * quality {"),
    ("never no faster", "if median >= Self.noFasterFraction * quality {", "if false {"),
    ("a verdict after every switch", "qualityMedian = speedHelps ? nil : median", "qualityMedian = median"),
    ("never a verdict", "qualityMedian = speedHelps ? nil : median", "qualityMedian = nil"),
    ("a retry with no room", "median.map({ $0 <= Self.headroomFraction * budget }) ?? true", "true"),
    ("no retry while still", "median.map({ $0 <= Self.headroomFraction * budget }) ?? true", "median.map({ $0 <= Self.headroomFraction * budget }) ?? false"),
    ("a retry at once", "guard now - since >= retry, median", "guard now - since >= 0, median"),
    ("the wait never doubles", "min(retry * 2, Self.maxRetryAfter)", "Self.retryAfter"),
    ("the wait doubles without bound", "min(retry * 2, Self.maxRetryAfter)", "retry * 2"),
    ("the wait never resets", "retrying && lasted < Self.maxRetryAfter ? min(retry * 2, Self.maxRetryAfter) : Self.retryAfter", "retrying ? min(retry * 2, Self.maxRetryAfter) : retry"),
    ("a swap keeps the setting", "        if let next = pending { speed = next }\n", ""),
    ("an unmade switch left pending", "        guard pending != nil else { return }\n        pending = nil\n        since = now\n", "        guard pending != nil else { return }\n        since = now\n"),
    ("an unmade switch judged at once", "        guard pending != nil else { return }\n        pending = nil\n        since = now\n", "        guard pending != nil else { return }\n        pending = nil\n"),
    ("a swap judged at once", "        if let next = pending { speed = next }\n        pending = nil\n        since = now\n", "        if let next = pending { speed = next }\n        pending = nil\n"),
    ("starting fast without speed", "        speed = startFast\n", "        speed = false\n"),
    ("starting fast still judged", "        speedHelps = startFast\n", "        speedHelps = false\n"),
    ("the line's frame time", "over the \\(ms(1 / Double(max(fps, 1)))) a frame has", "over the \\(ms(1 / Double(max(fps, 1)) * 0.9)) a frame has"),
]
ok = True
caught = 0
for i, (name, old, new) in enumerate(mutants, 1):
    if src.count(old) != 1:
        print(f"M{i:02} BAD      {name}: the text to change is found {src.count(old)} times"); ok = False; continue
    d = os.path.join(out, f"m{i:02}"); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "EncoderSpeedJudge.swift"), "w").write(src.replace(old, new))
    b = subprocess.run(["swiftc", "-O", os.path.join(d, "EncoderSpeedJudge.swift"), os.path.join(here, "main.swift"), "-o", os.path.join(d, "check")],
                       capture_output=True, text=True)
    if b.returncode != 0:
        print(f"M{i:02} NOBUILD  {name}: {b.stderr.strip().splitlines()[0] if b.stderr.strip() else '?'}"); ok = False; continue
    if "VideoToolbox" in subprocess.run(["otool", "-L", os.path.join(d, "check")], capture_output=True, text=True).stdout:
        print(f"M{i:02} REFUSED  {name}: the binary links VideoToolbox"); ok = False; continue
    r = subprocess.run([os.path.join(d, "check")], capture_output=True, text=True, timeout=120)
    fails = [l for l in r.stdout.splitlines() if "FAIL" in l]
    if r.returncode != 0:
        caught += 1
        print(f"M{i:02} CAUGHT   {name}: {len(fails) - 1} failures, first: {fails[0].strip() if fails else '?'}")
    else:
        ok = False
        print(f"M{i:02} MISSED   {name}")
print(f"{caught} of {len(mutants)} mutants caught")
sys.exit(0 if ok and caught == len(mutants) else 1)
