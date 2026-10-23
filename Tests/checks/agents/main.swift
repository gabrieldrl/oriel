import Foundation

// The Mac's coding agents (docs/agents-plan.md), against Sources/StreamProtocol and the host's
// AgentPolicy.swift compiled into this binary (build.sh).
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
func json<T: Encodable>(_ x: T) -> String { String(decoding: try! sorted.encode(x), as: UTF8.self) }

// MARK: - The wire

check(StreamMessageKind.agents.rawValue == 53 && StreamMessageKind.agentQuery.rawValue == 54, "kinds 53 and 54")
check(json(AgentQuery(token: 3, days: 30, usage: true)) == #"{"days":30,"token":3,"usage":true}"#, "a query: \(json(AgentQuery(token: 3, days: 30, usage: true)))")
check(json(AgentQuery()) == "{}", "an empty query asks for everything")
check(Wire.decode(AgentQuery.self, from: Data(#"{"token":1,"later":true}"#.utf8))?.token == 1, "a later field is skipped")
check(!json(WindowList(macName: "Mac", windows: [], active: .desktop)).contains("agents"), "the window list says nothing of agents: the link carries them")
let report = AgentReport(answering: 2, at: 100, providers: [
    AgentProvider(id: "claude", name: "Claude", installed: true, version: "2.1.296",
                  usage: AgentUsage(limits: [AgentLimit(id: "five_hour", name: "5-hour", usedPercent: 12.5, resetsAt: 200)], plan: "max", asOf: 100),
                  sessions: [AgentSession(id: "a", provider: "claude", title: "Fix it", project: "/p", updatedAt: 90, running: true)])])
check(Wire.decode(AgentReport.self, from: Wire.encode(report)) == report, "a report reads back as it went")
check(Wire.decode(AgentProvider.self, from: Data(#"{"id":"gemini","name":"Gemini","installed":false,"sessions":[]}"#.utf8))?.id == "gemini",
      "a later agent is a string, not a case")

// MARK: - Claude Code's transcripts

func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
let head = [
    line(["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-10-22T10:00:00.000Z"]),
    line(["type": "user", "isMeta": true, "cwd": "/Users/me/sill", "gitBranch": "dev", "timestamp": "2026-10-22T10:00:01.000Z",
          "message": ["role": "user", "content": "<local-command-caveat>Caveat: the messages below…"]]),
    line(["type": "user", "cwd": "/Users/me/sill", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]]),
    line(["type": "user", "isSidechain": true, "message": ["role": "user", "content": "a subagent's prompt"]]),
    line(["type": "user", "cwd": "/Users/me/sill", "timestamp": "2026-10-22T10:00:02.000Z",
          "message": ["role": "user", "content": [["type": "text", "text": "  Run it on the iPad\nand rebuild"], ["type": "image"]]]]),
]
let tail = [
    line(["type": "custom-title", "customTitle": "Old name"]),
    line(["type": "assistant", "timestamp": "2026-10-22T11:00:00.000Z", "gitBranch": "feature",
          "message": ["model": "claude-opus-5-5", "role": "assistant"]]),
    line(["type": "assistant", "timestamp": "2026-10-22T11:30:00.500Z", "message": ["model": "<synthetic>"]]),
    line(["type": "custom-title", "customTitle": "Sill repository setup"]),
    line(["type": "last-prompt", "lastPrompt": "commit it"]),
    "{\"type\":\"user\",\"cut",
]
let s = AgentPolicy.claudeSession(id: "abc", head: head, tail: tail, modified: 5)
check(s?.title == "Sill repository setup", "the newest name: \(s?.title ?? "nil")")
check(s?.project == "/Users/me/sill", "the folder: \(s?.project ?? "nil")")
check(s?.branch == "feature", "the newest branch: \(s?.branch ?? "nil")")
check(s?.model == "claude-opus-5-5", "the model, not a synthetic one: \(s?.model ?? "nil")")
check(s?.updatedAt == AgentPolicy.timestamp("2026-10-22T11:30:00.500Z"), "the last activity: \(s?.updatedAt ?? 0)")
check(s?.createdAt == AgentPolicy.timestamp("2026-10-22T10:00:00.000Z"), "the start")
check(s?.provider == "claude" && s?.id == "abc", "Claude's, by its file's name")
let unnamed = AgentPolicy.claudeSession(id: "b", head: head, tail: Array(tail.dropFirst(4)), modified: 5)
check(unnamed?.title == "Run it on the iPad", "no name: the first prompt's first line: \(unnamed?.title ?? "nil")")
let onlyLast = AgentPolicy.claudeSession(id: "c", head: Array(head.prefix(4)), tail: [line(["type": "last-prompt", "lastPrompt": "commit it"])], modified: 5)
check(onlyLast?.title == "commit it", "no name nor prompt: the last prompt: \(onlyLast?.title ?? "nil")")
let undated = AgentPolicy.claudeSession(id: "d", head: [line(["type": "user", "message": ["content": "hi"]])], tail: [], modified: 77)
check(undated?.updatedAt == 77 && undated?.title == "hi", "nothing dated: the file's time")
check(AgentPolicy.claudeSession(id: "e", head: ["not json"], tail: [], modified: 1) == nil, "nothing readable: no session")
check(AgentPolicy.claudeSession(id: "f", head: [line(["type": "mode"])], tail: [], modified: 1)?.title == "Untitled", "no words at all: Untitled")
for m in AgentPolicy.machineWords {
    check(AgentPolicy.prompt(["type": "user", "message": ["content": m + " x"]]) == nil, "not a prompt: \(m)")
}
check(AgentPolicy.prompt(["type": "assistant", "message": ["content": "hi"]]) == nil, "an answer is not a prompt")
check(AgentPolicy.prompt(["type": "user", "isMeta": true, "message": ["content": "plain words"]]) == nil, "a meta record is not a prompt")
check(AgentPolicy.prompt(["type": "user", "message": ["content": [["type": "tool_result", "content": "x"]]]]) == nil, "a tool's result is not a prompt")

// MARK: - Titles

check(AgentPolicy.title("\n\n  hello   there \nsecond") == "hello there", "one line, spaces collapsed")
check(AgentPolicy.title("   \n ") == nil, "nothing left")
let long = String(repeating: "a", count: 300)
check(AgentPolicy.title(long)?.count == AgentSession.titleLength && AgentPolicy.title(long)?.hasSuffix("…") == true, "cut with an ellipsis")
check(AgentPolicy.title(String(repeating: "b", count: AgentSession.titleLength)) == String(repeating: "b", count: AgentSession.titleLength), "exactly the length: kept")

// MARK: - Lines of a read

let bytes = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3".utf8)
check(AgentPolicy.lines(bytes, cutStart: false, cutEnd: true) == ["{\"a\":1}", "{\"b\":2}"], "a cut end drops the last line")
check(AgentPolicy.lines(bytes, cutStart: true, cutEnd: false) == ["{\"b\":2}", "{\"c\":3"], "a cut start drops the first")
check(AgentPolicy.lines(Data("{\"a\":1}\n".utf8), cutStart: false, cutEnd: true) == ["{\"a\":1}"], "a whole last line stays")

// MARK: - Running sessions

let pidFile = Data(#"{"pid":29670,"sessionId":"41509519","cwd":"/x"}"#.utf8)
check(AgentPolicy.runningClaudeSession(pidFile, alive: { $0 == 29670 }) == "41509519", "a live process's session")
check(AgentPolicy.runningClaudeSession(pidFile, alive: { _ in false }) == nil, "a dead one's is not running")

// MARK: - Codex's limits

let codex = line(["timestamp": "2026-10-18T21:20:00.000Z", "type": "event_msg", "payload": [
    "type": "token_count", "info": NSNull(),
    "rate_limits": ["primary": ["used_percent": 1.0, "window_minutes": 10080, "resets_at": 1792949825],
                    "secondary": ["used_percent": 40.5, "window_minutes": 300, "resets_in_seconds": 600],
                    "credits": ["has_credits": true, "unlimited": false, "balance": "62427.6342370000"], "plan_type": "pro"]]])
let u = AgentPolicy.codexUsage(codex)
check(u?.limits.map(\.name) == ["Weekly", "5-hour"], "named by window: \(u?.limits.map(\.name) ?? [])")
check(u?.limits.first?.usedPercent == 1 && u?.limits.first?.resetsAt == 1792949825, "the week's: used and reset")
check(u?.limits.last?.resetsAt == AgentPolicy.timestamp("2026-10-18T21:20:00.000Z")! + 600, "a reset in seconds counts from the line")
check(u?.plan == "pro" && u?.credits == "62427.6342370000", "the plan and the credits")
check(u?.asOf == AgentPolicy.timestamp("2026-10-18T21:20:00.000Z"), "as of the line's time")
check(AgentPolicy.codexUsage(line(["type": "event_msg", "timestamp": "2026-10-18T21:20:00.000Z",
                                   "payload": ["type": "token_count", "rate_limits": ["primary": NSNull()]]])) == nil, "no limit in it: nothing")
check(AgentPolicy.codexUsage(line(["type": "event_msg", "payload": ["type": "agent_message", "rate_limits": [:]]])) == nil, "not a token count")
check(AgentPolicy.codexUsage(line(["type": "event_msg", "payload": ["type": "token_count",
                                   "rate_limits": ["primary": ["used_percent": 5]]]])) == nil, "undated: nothing")
let unlimited = line(["timestamp": "2026-10-18T21:20:00Z", "type": "event_msg", "payload": ["type": "token_count",
                      "rate_limits": ["primary": ["used_percent": 2], "credits": ["unlimited": true]]]])
check(AgentPolicy.codexUsage(unlimited)?.credits == "unlimited", "unlimited credits")
check(AgentPolicy.codexUsage(unlimited)?.limits.first?.name == "Primary", "no window: its key")
check(AgentPolicy.limitName(minutes: 300) == "5-hour" && AgentPolicy.limitName(minutes: 4320) == "3-day"
      && AgentPolicy.limitName(minutes: 90) == "90-minute" && AgentPolicy.limitName(minutes: nil) == nil, "window names")

// MARK: - Claude's usage endpoint

let answer = Data(#"{"seven_day_opus":{"utilization":3,"resets_at":null},"seven_day":{"utilization":41.0,"resets_at":"2026-10-25T09:00:00.877434+00:00"},"five_hour":{"utilization":12.5,"resets_at":"2026-10-22T15:00:00+00:00"},"extra_usage":{"is_enabled":false}}"#.utf8)
let cu = AgentPolicy.claudeUsage(answer, plan: "max", now: 50)
check(cu?.limits.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"], "5-hour, the week, then the rest: \(cu?.limits.map(\.id) ?? [])")
check(cu?.limits.map(\.name) == ["5-hour", "Weekly", "Weekly Opus"], "their names: \(cu?.limits.map(\.name) ?? [])")
check(abs((cu?.limits[1].resetsAt ?? 0) - AgentPolicy.timestamp("2026-10-25T09:00:00Z")!) < 1, "a long fraction is read")
check(cu?.limits[0].usedPercent == 12.5 && cu?.limits[2].resetsAt == nil, "used, and no reset")
check(cu?.plan == "max" && cu?.asOf == 50, "the plan, as of now")
check(AgentPolicy.claudeUsage(Data("{}".utf8), plan: nil, now: 1) == nil, "no limit: nothing")
check(AgentPolicy.claudeUsage(Data("not json".utf8), plan: nil, now: 1) == nil, "not JSON: nothing")
check(AgentPolicy.claudeLimitName("seven_day_oauth_apps") == "Weekly Oauth Apps" && AgentPolicy.claudeLimitName("monthly_cap") == "Monthly Cap", "other names")

// MARK: - The sign-in

let good = Data(#"{"claudeAiOauth":{"accessToken":"t0k","refreshToken":"r","expiresAt":2000000,"subscriptionType":"max"}}"#.utf8)
check(AgentPolicy.claudeSignIn(good, now: 1000) == .token("t0k", plan: "max"), "a good token and its plan")
check(AgentPolicy.claudeSignIn(good, now: 2000) == .expired, "at its expiry: expired")
check(AgentPolicy.claudeSignIn(Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8), now: 1e12) == .token("t", plan: nil), "no expiry: used")
check(AgentPolicy.claudeSignIn(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8), now: 1) == .signedOut, "an empty token: signed out")
check(AgentPolicy.claudeSignIn(Data("{}".utf8), now: 1) == .signedOut, "nothing: signed out")

// MARK: - A query's sessions

let now = 1_000_000.0
let many = (0..<10).map { AgentSession(id: "s\($0)", provider: "codex", title: "t", updatedAt: now - Double($0) * 86_400) }
let week = AgentPolicy.pick(many, days: 7, limit: nil, now: now)
check(week.sessions.map(\.id) == ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"], "the last 7 days, newest first: \(week.sessions.map(\.id))")
check(!week.more, "nothing left out")
let three = AgentPolicy.pick(many.shuffled(), days: nil, limit: 3, now: now)
check(three.sessions.map(\.id) == ["s0", "s1", "s2"] && three.more, "every day, at most 3, more left")
check(AgentPolicy.pick(many, days: nil, limit: 10_000, now: now).sessions.count == 10, "a limit above the most is the most")
check(AgentPolicy.pick(many, days: 0, limit: nil, now: now).sessions.count == 10, "0 days: every one")
let crowd = (0..<(AgentReport.maxSessions + 20)).map { AgentSession(id: "c\($0)", provider: "claude", title: "t", updatedAt: Double($0)) }
let capped = AgentPolicy.pick(crowd, days: nil, limit: 10_000, now: now)
check(capped.sessions.count == AgentReport.maxSessions && capped.more, "never more than the most a report carries: \(capped.sessions.count)")
check(AgentPolicy.pick(many, days: nil, limit: 0, now: now).sessions.count == 1, "a limit of 0 is 1")
check(AgentPolicy.cutoff(days: 30, now: now) == now - 30 * 86_400 && AgentPolicy.cutoff(days: nil, now: now) == -.infinity, "the cutoff")
let tie = [AgentSession(id: "a", provider: "c", title: "", updatedAt: 5), AgentSession(id: "b", provider: "c", title: "", updatedAt: 5)]
check(AgentPolicy.pick(tie, days: nil, limit: nil, now: 6).sessions.map(\.id) == ["b", "a"], "a tie keeps one order")
check(AgentReport.maxSessions == 500 && AgentPolicy.defaultLimit == 200, "the limits")

// MARK: - Turns that end (docs/background-plan.md)

let ended = [
    line(["type": "assistant", "message": ["id": "m1", "stop_reason": "tool_use"]]),
    line(["type": "assistant", "message": ["id": "m2", "stop_reason": "end_turn"]]),
    line(["type": "assistant", "message": ["id": "m2", "stop_reason": "end_turn"]]),
    line(["type": "assistant", "isSidechain": true, "message": ["id": "s1", "stop_reason": "end_turn"]]),
    line(["type": "user", "message": ["id": "u1", "stop_reason": "end_turn"]]),
    line(["type": "assistant", "message": ["id": "m3", "stop_reason": "end_turn"]]),
    #"{"type":"assistant","cut"#,
]
check(AgentPolicy.claudeTurnEnds(ended) == ["m2", "m3"], "Claude: end_turn, one per message, off side chains: \(AgentPolicy.claudeTurnEnds(ended))")
check(AgentPolicy.claudeTurnEnds([line(["type": "assistant", "message": ["stop_reason": "max_tokens"]])]).isEmpty, "a turn cut short is no finish")
let codexLines = [
    line(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "t1"]]),
    line(["type": "event_msg", "payload": ["type": "turn_aborted", "turn_id": "t1"]]),
    line(["type": "response_item", "payload": ["type": "task_complete", "turn_id": "x"]]),
    line(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t2"]]),
]
check(AgentPolicy.codexTurnEnds(codexLines) == ["t2"], "Codex: an event's task_complete, not an aborted turn: \(AgentPolicy.codexTurnEnds(codexLines))")
check(AgentPolicy.codexThread(fileName: "rollout-2026-10-18T22-14-34-01A150DD-c72e-7ec0-8078-2e17edeb0039.jsonl") == "01a150dd-c72e-7ec0-8078-2e17edeb0039",
      "Codex: the thread from the file's name")
check(AgentPolicy.codexThread(fileName: "rollout-short.jsonl") == nil && AgentPolicy.codexThread(fileName: "notes-01a150dd-c72e-7ec0-8078-2e17edeb0039.jsonl") == nil,
      "Codex: only a rollout's name")
check(AgentPolicy.codexSubagent(source: #"{"subagent":{"other":"guardian"}}"#) && !AgentPolicy.codexSubagent(source: "vscode")
      && !AgentPolicy.codexSubagent(source: nil), "Codex: a sub-agent's thread")
let appended = Data("{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8)
let whole = AgentPolicy.complete(appended)
check(whole.lines == [#"{"a":1}"#, #"{"b":2}"#] && whole.consumed == 16, "appended bytes: whole lines only, the rest waits: \(whole)")
check(AgentPolicy.complete(Data("{\"c\"".utf8)).consumed == 0, "no newline yet: nothing read")
check(AgentPolicy.finishQuiet == 10, "one finish per session in 10 s")

print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
