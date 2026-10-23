import Foundation
import StreamProtocol

/// What the Mac's coding agents' own files say, read into the wire's shapes (docs/agents-plan.md).
/// Pure: AgentReaders hands it lines and bytes; `Tests/checks/agents` checks it.
///
/// 1. A Claude Code transcript is JSON lines. Its first lines give the folder, the branch, the start
///    and the first prompt; its last lines the newest name (`custom-title`), the last prompt
///    (`last-prompt`), the model and the last activity. A session's title is its name, else its first
///    prompt, else its last prompt, one line of at most `AgentSession.titleLength` characters.
///    What Claude Code writes for itself is never a prompt: meta records, side chains, its commands'
///    and tools' output.
/// 2. Codex's rate limits are in its session files' `token_count` events: the last one with a
///    `rate_limits` is the newest known.
/// 3. Claude's usage endpoint answers an object per limit, `utilization` (0…100) and `resets_at`.
/// 4. A query's sessions: active in its last `days`, the newest first, at most `limit`.
/// 5. A turn's end (docs/background-plan.md): in Claude Code's transcript an `assistant` record whose
///    `stop_reason` is `end_turn`, off the side chains; in a Codex session file an `event_msg` whose
///    payload is `task_complete`. A sub-agent's Codex thread (`source` `{"subagent"…`) is no one's
///    session.
enum AgentPolicy {
    /// How much of a transcript's start and end is read.
    static let headBytes = 64 * 1024
    static let tailBytes = 128 * 1024
    /// Sessions in a report when the query names no limit.
    static let defaultLimit = 200

    // MARK: Claude Code's transcripts

    /// One transcript's session, from its first and last lines; nil when nothing in it is a session.
    /// `modified` (its file's) stands in for a last activity no record dates.
    static func claudeSession(id: String, head: [String], tail: [String], modified: Double) -> AgentSession? {
        let first = head.compactMap(record)
        let last = tail.compactMap(record)
        guard !first.isEmpty || !last.isEmpty else { return nil }
        var name: String?
        var lastPrompt: String?
        var model: String?
        var branch: String?
        var updated: Double?
        for r in last {
            if r["type"] as? String == "custom-title", let t = r["customTitle"] as? String { name = t }
            if r["type"] as? String == "last-prompt", let t = r["lastPrompt"] as? String { lastPrompt = t }
            if r["type"] as? String == "assistant", let m = (r["message"] as? [String: Any])?["model"] as? String,
               !m.hasPrefix("<") { model = m }
            if let b = r["gitBranch"] as? String, !b.isEmpty { branch = b }
            if let t = (r["timestamp"] as? String).flatMap(timestamp) { updated = max(updated ?? t, t) }
        }
        var project: String?
        var created: Double?
        var firstPrompt: String?
        for r in first {
            if project == nil, let c = r["cwd"] as? String, !c.isEmpty { project = c }
            if created == nil, let t = (r["timestamp"] as? String).flatMap(timestamp) { created = t }
            if branch == nil, let b = r["gitBranch"] as? String, !b.isEmpty { branch = b }
            if name == nil, r["type"] as? String == "custom-title", let t = r["customTitle"] as? String { name = t }
            if firstPrompt == nil, let p = prompt(r) { firstPrompt = p }
        }
        if project == nil { project = last.lazy.compactMap { $0["cwd"] as? String }.first { !$0.isEmpty } }
        let title = [name, firstPrompt, lastPrompt].lazy.compactMap { $0.flatMap(Self.title) }.first ?? "Untitled"
        return AgentSession(id: id, provider: AgentProvider.claude, title: title, project: project, branch: branch,
                            model: model, updatedAt: updated ?? modified, createdAt: created)
    }

    /// A user's own words in a record: its text, or its text blocks joined; nil for anything Claude
    /// Code wrote itself.
    static func prompt(_ r: [String: Any]) -> String? {
        guard r["type"] as? String == "user", r["isMeta"] as? Bool != true, r["isSidechain"] as? Bool != true,
              let message = r["message"] as? [String: Any] else { return nil }
        let text: String
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        } else {
            return nil
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !machineWords.contains(where: { t.hasPrefix($0) }) else { return nil }
        return t
    }

    /// How what Claude Code writes in a user's place begins: a command's echo, its output, a note.
    static let machineWords = ["<command-", "<local-command", "<system-reminder>", "<bash-", "<task-notification>",
                               "Caveat:", "[Request interrupted"]

    /// One line, spaces collapsed, at most `AgentSession.titleLength` characters (an ellipsis when cut);
    /// nil when nothing is left.
    static func title(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        guard line.count > AgentSession.titleLength else { return line }
        return String(line.prefix(AgentSession.titleLength - 1)) + "…"
    }

    /// The running Claude Code sessions, from `~/.claude/sessions/<pid>.json`: its `sessionId` when
    /// `alive(pid)`.
    static func runningClaudeSession(_ data: Data, alive: (Int32) -> Bool) -> String? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (r["pid"] as? NSNumber)?.int32Value, let id = r["sessionId"] as? String, alive(pid) else { return nil }
        return id
    }

    // MARK: Codex's rate limits

    /// The limits in one session-file line, when it is a `token_count` event that carries them.
    static func codexUsage(_ line: String) -> AgentUsage? {
        guard line.contains("\"rate_limits\""), let r = record(line),
              let payload = r["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let at = (r["timestamp"] as? String).flatMap(timestamp)
        var out: [AgentLimit] = []
        for key in ["primary", "secondary"] {
            guard let l = limits[key] as? [String: Any], let used = (l["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let window = (l["window_minutes"] as? NSNumber)?.intValue
            var resets = (l["resets_at"] as? NSNumber)?.doubleValue
            if resets == nil, let inSeconds = (l["resets_in_seconds"] as? NSNumber)?.doubleValue, let at { resets = at + inSeconds }
            out.append(AgentLimit(id: key, name: limitName(minutes: window) ?? key.capitalized, usedPercent: used,
                                  resetsAt: resets, windowMinutes: window))
        }
        guard !out.isEmpty, let at else { return nil }
        let credits = (limits["credits"] as? [String: Any]).flatMap { c -> String? in
            if c["unlimited"] as? Bool == true { return "unlimited" }
            return c["balance"] as? String ?? (c["balance"] as? NSNumber)?.stringValue
        }
        return AgentUsage(limits: out, plan: limits["plan_type"] as? String, asOf: at, credits: credits)
    }

    /// "5-hour", "Weekly", "3-day", "90-minute".
    static func limitName(minutes: Int?) -> String? {
        guard let m = minutes, m > 0 else { return nil }
        if m == 7 * 24 * 60 { return "Weekly" }
        if m % (24 * 60) == 0 { return "\(m / (24 * 60))-day" }
        if m % 60 == 0 { return "\(m / 60)-hour" }
        return "\(m)-minute"
    }

    // MARK: Claude's usage endpoint

    /// Its answer's limits, the 5-hour first, then the week's, then the rest by name; nil when none.
    static func claudeUsage(_ data: Data, plan: String?, now: Double) -> AgentUsage? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [AgentLimit] = []
        for (key, value) in r {
            guard let l = value as? [String: Any], let used = (l["utilization"] as? NSNumber)?.doubleValue else { continue }
            out.append(AgentLimit(id: key, name: claudeLimitName(key), usedPercent: used,
                                  resetsAt: (l["resets_at"] as? String).flatMap(timestamp)))
        }
        guard !out.isEmpty else { return nil }
        let order = ["five_hour": 0, "seven_day": 1]
        out.sort { (order[$0.id] ?? 2, $0.id) < (order[$1.id] ?? 2, $1.id) }
        return AgentUsage(limits: out, plan: plan, asOf: now)
    }

    /// `five_hour` "5-hour", `seven_day` "Weekly", `seven_day_opus` "Weekly Opus".
    static func claudeLimitName(_ key: String) -> String {
        if key == "five_hour" { return "5-hour" }
        if key == "seven_day" { return "Weekly" }
        if key.hasPrefix("seven_day_") {
            return "Weekly " + key.dropFirst("seven_day_".count).split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
        return key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    /// Claude Code's sign-in, from its Keychain item: the token while it is good, else why not.
    enum SignIn: Equatable {
        case token(String, plan: String?)
        case expired
        case signedOut
    }

    static func claudeSignIn(_ data: Data, now: Double) -> SignIn {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = r["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .signedOut }
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms / 1000 <= now { return .expired }
        return .token(token, plan: oauth["subscriptionType"] as? String)
    }

    // MARK: A query's sessions

    /// Active in the last `days` (all with nil), the newest first, at most `limit` (`defaultLimit` with
    /// nil, never more than `AgentReport.maxSessions`); `more` when some were left out.
    static func pick(_ sessions: [AgentSession], days: Int?, limit: Int?, now: Double) -> (sessions: [AgentSession], more: Bool) {
        let cutoff = cutoff(days: days, now: now)
        let n = min(max(limit ?? defaultLimit, 1), AgentReport.maxSessions)
        let recent = sessions.filter { $0.updatedAt >= cutoff }.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        return (Array(recent.prefix(n)), recent.count > n)
    }

    /// The oldest last activity a query of `days` takes: -infinity for every session.
    static func cutoff(days: Int?, now: Double) -> Double {
        guard let days, days > 0 else { return -.infinity }
        return now - Double(days) * 86_400
    }

    // MARK: Turns that end

    /// The turns that ended in these new lines of a Claude Code transcript: each one's message id (a
    /// message written as several records counts once), in order.
    static func claudeTurnEnds(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            guard let r = record(line), r["type"] as? String == "assistant", r["isSidechain"] as? Bool != true,
                  let message = r["message"] as? [String: Any], message["stop_reason"] as? String == "end_turn" else { continue }
            let id = message["id"] as? String ?? r["uuid"] as? String ?? "\(out.count)"
            if out.last != id { out.append(id) }
        }
        return out
    }

    /// The turns that ended in these new lines of a Codex session file: each one's turn id, in order.
    static func codexTurnEnds(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            guard let r = record(line), r["type"] as? String == "event_msg",
                  let payload = r["payload"] as? [String: Any], payload["type"] as? String == "task_complete" else { return nil }
            return payload["turn_id"] as? String ?? r["timestamp"] as? String ?? "turn"
        }
    }

    /// A Codex session file's thread: the id that ends its name,
    /// `rollout-2026-10-18T22-14-34-01a150dd-c72e-7ec0-8078-2e17edeb0039.jsonl`.
    static func codexThread(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-"), fileName.hasSuffix(".jsonl") else { return nil }
        let stem = fileName.dropLast(".jsonl".count)
        guard stem.count >= 36 else { return nil }
        let id = String(stem.suffix(36))
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }

    /// A Codex thread a sub-agent runs (a review, a spawned explorer).
    static func codexSubagent(source: String?) -> Bool {
        source?.trimmingCharacters(in: .whitespaces).hasPrefix(#"{"subagent""#) == true
    }

    /// The whole lines in bytes appended to a file, and how many bytes they were: a line still being
    /// written waits for its newline.
    static func complete(_ data: Data) -> (lines: [String], consumed: Int) {
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let whole = data[data.startIndex...last]
        return (lines(Data(whole), cutStart: false, cutEnd: false), whole.count)
    }

    /// One notification per session in this long: two turns ending together are one finish.
    static let finishQuiet: Double = 10

    // MARK: Pieces

    /// One JSON line as an object; nil for anything else (a line cut at the read's edge).
    static func record(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The whole lines of a read: its last line dropped when the read stopped inside it (`cutEnd`),
    /// its first when it started inside one (`cutStart`).
    static func lines(_ data: Data, cutStart: Bool, cutEnd: Bool) -> [String] {
        var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if cutEnd, data.last != UInt8(ascii: "\n"), !parts.isEmpty { parts.removeLast() }
        if cutStart, !parts.isEmpty { parts.removeFirst() }
        return parts.compactMap { $0.isEmpty ? nil : String(data: Data($0), encoding: .utf8) }
    }

    /// "2026-10-18T21:14:34.985Z", "2026-10-18T21:14:34+00:00" as seconds since 1970; a fraction the
    /// formatter refuses counts to the second.
    static func timestamp(_ iso: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d.timeIntervalSince1970 }
        guard let dot = iso.firstIndex(of: "."), iso[iso.index(after: dot)...].first?.isNumber == true else { return nil }
        let rest = iso[iso.index(after: dot)...].drop { $0.isNumber }
        return f.date(from: String(iso[..<dot]) + rest)?.timeIntervalSince1970
    }
}
