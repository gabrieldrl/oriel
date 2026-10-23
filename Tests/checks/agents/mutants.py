"""Mutants of the agents check: each changes one file it compiles in one place, and must make the check
fail. usage: mutants.py WORKTREE"""
import os, subprocess, sys, tempfile
WT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
PATHS = {
    "StreamMessage.swift": "Sources/StreamProtocol/StreamMessage.swift",
    "AgentPolicy.swift": "Sources/SillHost/Agents/AgentPolicy.swift",
}
MUTANTS = [
    ("the query kind at 55", "StreamMessage.swift", "case agentQuery = 54", "case agentQuery = 59"),
    ("the first name wins", "AgentPolicy.swift", 'if r["type"] as? String == "custom-title", let t = r["customTitle"] as? String { name = t }',
     'if name == nil, r["type"] as? String == "custom-title", let t = r["customTitle"] as? String { name = t }'),
    ("a synthetic model kept", "AgentPolicy.swift", "!m.hasPrefix(\"<\") { model = m }", "true { model = m }"),
    ("the first prompt before the name", "AgentPolicy.swift", "[name, firstPrompt, lastPrompt]", "[firstPrompt, name, lastPrompt]"),
    ("meta records are prompts", "AgentPolicy.swift", 'r["isMeta"] as? Bool != true, ', ""),
    ("side chains are prompts", "AgentPolicy.swift", 'r["isMeta"] as? Bool != true, r["isSidechain"] as? Bool != true,', 'r["isMeta"] as? Bool != true,'),
    ("no ellipsis", "AgentPolicy.swift", 'return String(line.prefix(AgentSession.titleLength - 1)) + "…"', "return String(line.prefix(AgentSession.titleLength))"),
    ("a cut end kept", "AgentPolicy.swift", "if cutEnd, data.last != UInt8(ascii: \"\\n\"), !parts.isEmpty { parts.removeLast() }", ""),
    ("the week named by hours", "AgentPolicy.swift", 'if m == 7 * 24 * 60 { return "Weekly" }', ""),
    ("resets in seconds ignored", "AgentPolicy.swift", "if resets == nil, let inSeconds", "if false, let inSeconds"),
    ("Claude's order lost", "AgentPolicy.swift", '["five_hour": 0, "seven_day": 1]', '["five_hour": 1, "seven_day": 0]'),
    ("an expired token used", "AgentPolicy.swift", "ms / 1000 <= now { return .expired }", "ms / 1000 <= now - 1e12 { return .expired }"),
    ("oldest first", "AgentPolicy.swift", "($0.updatedAt, $0.id) > ($1.updatedAt, $1.id)", "($0.updatedAt, $0.id) < ($1.updatedAt, $1.id)"),
    ("no cap", "AgentPolicy.swift", "min(max(limit ?? defaultLimit, 1), AgentReport.maxSessions)", "max(limit ?? defaultLimit, 1)"),
    ("days ignored", "AgentPolicy.swift", "guard let days, days > 0 else { return -.infinity }", "guard let days, days < 0 else { return -.infinity }"),
    ("any stop is a finish", "AgentPolicy.swift", 'message["stop_reason"] as? String == "end_turn" else { continue }', 'message["stop_reason"] != nil else { continue }'),
    ("a message counted twice", "AgentPolicy.swift", "if out.last != id { out.append(id) }", "out.append(id)"),
    ("side chains finish", "AgentPolicy.swift", 'r["type"] as? String == "assistant", r["isSidechain"] as? Bool != true,\n                  let message = r["message"] as? [String: Any], message["stop_reason"]', 'r["type"] as? String == "assistant",\n                  let message = r["message"] as? [String: Any], message["stop_reason"]'),
    ("Codex: any record's task_complete", "AgentPolicy.swift", 'guard let r = record(line), r["type"] as? String == "event_msg",', "guard let r = record(line),"),
    ("sub-agents are sessions", "AgentPolicy.swift", r'''hasPrefix(#"{"subagent""#)''', r'''hasPrefix(#"{"never""#)'''),
    ("a half line read", "AgentPolicy.swift", r'''guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }''', "guard let last = data.indices.last else { return ([], 0) }"),
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
