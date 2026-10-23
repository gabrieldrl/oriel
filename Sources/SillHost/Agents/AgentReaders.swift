import Foundation
import Security
import SQLite3
import StreamProtocol

// The Mac's coding agents as their own files, database and service say (docs/agents-plan.md). What
// those say is read by AgentPolicy; this is the reading. Every reader here runs on the agents' queue (AgentsFeature)
// alone, never the main thread: a Keychain prompt or a slow disk waits there.

/// An agent's command-line tool: where it is and its version.
enum AgentTools {
    /// The usual homes of a tool installed by its own installer, Homebrew or npm, then `PATH`.
    static func find(_ name: String, home: URL) -> URL? {
        let dirs = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
                    home.appendingPathComponent(".npm-global/bin").path, home.appendingPathComponent(".bun/bin").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs where !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private static var versions: [String: String] = [:]
    private static let versionsLock = NSLock()

    /// `tool --version`'s first word that starts with a digit ("2.1.296"), once per tool per process;
    /// nil when it does not answer within 5 s.
    static func version(_ tool: URL) -> String? {
        versionsLock.lock()
        if let v = versions[tool.path] { versionsLock.unlock(); return v }
        versionsLock.unlock()
        let p = Process()
        p.executableURL = tool
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let v = text.split(whereSeparator: \.isWhitespace).map(String.init).first(where: { $0.first?.isNumber == true })
        else { return nil }
        versionsLock.lock(); versions[tool.path] = v; versionsLock.unlock()
        return v
    }
}

/// Reads up to `count` bytes at `offset`; nil when the file cannot be read.
private func readBytes(_ url: URL, offset: UInt64, count: Int) -> Data? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    do {
        try h.seek(toOffset: offset)
        return try h.read(upToCount: count) ?? Data()
    } catch { return nil }
}

/// Claude Code's sessions: a summary of each transcript, kept by its path, size and modified time so
/// a query reads only the transcripts that changed. Used on the agents' queue (AgentsFeature) alone.
final class ClaudeReader: @unchecked Sendable {
    let home: URL
    private var known: [String: (size: Int, modified: Double, session: AgentSession?)] = [:]

    init(home: URL) { self.home = home }

    private var root: URL { home.appendingPathComponent(".claude") }
    var tool: URL? { AgentTools.find("claude", home: home) }
    var installed: Bool { tool != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("projects").path) }

    /// Every session active since `cutoff`, unsorted; those running now say so.
    func sessions(since cutoff: Double) -> [AgentSession] {
        let fm = FileManager.default
        let projects = root.appendingPathComponent("projects")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let running = runningSessions()
        var out: [AgentSession] = []
        var seen = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            where file.pathExtension == "jsonl" {
                guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize, let date = v.contentModificationDate else { continue }
                let modified = date.timeIntervalSince1970
                // A transcript last written before the cutoff has no activity after it.
                guard modified >= cutoff else { continue }
                seen.insert(file.path)
                let session: AgentSession?
                if let k = known[file.path], k.size == size, k.modified == modified {
                    session = k.session
                } else {
                    session = summary(file, size: size, modified: modified)
                    known[file.path] = (size, modified, session)
                }
                guard var s = session, s.updatedAt >= cutoff else { continue }
                if running.contains(s.id) { s.running = true }
                out.append(s)
            }
        }
        // Transcripts gone since: forgotten, as are any not looked at this time (older than the cutoff
        // stay, so a wider query reads them once).
        for path in known.keys where !seen.contains(path) && !fm.fileExists(atPath: path) { known[path] = nil }
        return out
    }

    /// One transcript's session as a list shows it, read again only when its file changed.
    func session(at file: URL) -> AgentSession? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let v = try? file.resourceValues(forKeys: keys), let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        let modified = date.timeIntervalSince1970
        if let k = known[file.path], k.size == size, k.modified == modified { return k.session }
        let s = summary(file, size: size, modified: modified)
        known[file.path] = (size, modified, s)
        return s
    }

    private func summary(_ file: URL, size: Int, modified: Double) -> AgentSession? {
        let id = file.deletingPathExtension().lastPathComponent
        let headCount = min(size, AgentPolicy.headBytes)
        guard let head = readBytes(file, offset: 0, count: headCount) else { return nil }
        let headLines = AgentPolicy.lines(head, cutStart: false, cutEnd: headCount < size)
        var tailLines: [String] = []
        if size > headCount {
            let start = max(headCount, size - AgentPolicy.tailBytes)
            if let tail = readBytes(file, offset: UInt64(start), count: size - start) {
                tailLines = AgentPolicy.lines(tail, cutStart: start > headCount, cutEnd: false)
            }
        } else {
            tailLines = headLines
        }
        return AgentPolicy.claudeSession(id: id, head: headLines, tail: tailLines, modified: modified)
    }

    /// The sessions of Claude Code processes alive now (`~/.claude/sessions/<pid>.json`).
    private func runningSessions() -> Set<String> {
        let dir = root.appendingPathComponent("sessions")
        var out = Set<String>()
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let id = AgentPolicy.runningClaudeSession(data, alive: { kill($0, 0) == 0 || errno == EPERM }) { out.insert(id) }
        }
        return out
    }
}

/// Codex's sessions, from its own database's `threads`, and its rate limits from its newest session
/// files. Used on the agents' queue (AgentsFeature) alone.
final class CodexReader: @unchecked Sendable {
    let home: URL
    /// The newest session files' limits, by path and modified time.
    private var usageSeen: (path: String, modified: Double, usage: AgentUsage?)?

    init(home: URL) { self.home = home }

    private var root: URL { home.appendingPathComponent(".codex") }
    var tool: URL? { AgentTools.find("codex", home: home) }
    var installed: Bool { tool != nil || database != nil }

    /// A thread updated this recently is taken as running.
    static let runningWithin: Double = 60

    /// `state_<n>.sqlite`, the highest `n`.
    private var database: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let n = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (n, name)
        }
        return numbered.max { $0.0 < $1.0 }.map { root.appendingPathComponent($0.1) }
    }

    /// The threads active since `cutoff`, not archived, the newest first, at most `limit` and whether
    /// more were left out.
    func sessions(since cutoff: Double, limit: Int, now: Double) -> (sessions: [AgentSession], more: Bool) {
        guard let path = database?.path else { return ([], false) }
        guard let db = Self.open(path) else { return ([], false) }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        // Only the columns this Codex has: a later one may rename or drop some.
        let have = columns(db, "threads")
        let wanted = ["id", "name", "title", "first_user_message", "cwd", "git_branch", "model", "tokens_used",
                      "created_at_ms", "updated_at_ms", "created_at", "updated_at", "source"]
        let picked = wanted.filter(have.contains)
        guard picked.contains("id"), picked.contains("updated_at_ms") || picked.contains("updated_at") else { return ([], false) }
        let updated = picked.contains("updated_at_ms") ? "updated_at_ms / 1000.0" : "updated_at"
        let archived = have.contains("archived") ? "archived = 0 AND " : ""
        // A sub-agent's thread (a review, a spawned explorer) is no one's session.
        let own = have.contains("source") ? "(source IS NULL OR source NOT LIKE '{\"subagent\"%') AND " : ""
        let sql = "SELECT \(picked.joined(separator: ", ")) FROM threads WHERE \(archived)\(own)\(updated) >= ? ORDER BY \(updated) DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return ([], false) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.isFinite ? cutoff : -1e18)
        sqlite3_bind_int(statement, 2, Int32(limit + 1))
        var out: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for (i, name) in picked.enumerated() {
                switch sqlite3_column_type(statement, Int32(i)) {
                case SQLITE_INTEGER: row[name] = Double(sqlite3_column_int64(statement, Int32(i)))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, Int32(i))
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, Int32(i)))
                default: break
                }
            }
            guard let id = row["id"] as? String else { continue }
            let up = (row["updated_at_ms"] as? Double).map { $0 / 1000 } ?? (row["updated_at"] as? Double) ?? 0
            let created = (row["created_at_ms"] as? Double).map { $0 / 1000 } ?? (row["created_at"] as? Double)
            let title = [row["name"], row["title"], row["first_user_message"]].lazy
                .compactMap { ($0 as? String).flatMap(AgentPolicy.title) }.first ?? "Untitled"
            out.append(AgentSession(id: id, provider: AgentProvider.codex, title: title,
                                    project: (row["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    branch: (row["git_branch"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    model: (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    updatedAt: up, createdAt: created,
                                    running: now - up < Self.runningWithin ? true : nil,
                                    tokens: (row["tokens_used"] as? Double).map { Int($0) }))
        }
        let more = out.count > limit
        return (Array(out.prefix(limit)), more)
    }

    /// One thread's title and folder, and whether a sub-agent runs it; nil when the database has no
    /// such thread (yet).
    func thread(_ id: String) -> (title: String, project: String?, subagent: Bool)? {
        guard let path = database?.path else { return nil }
        guard let db = Self.open(path) else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let have = columns(db, "threads")
        let picked = ["name", "title", "first_user_message", "cwd", "source"].filter(have.contains)
        guard have.contains("id"), !picked.isEmpty else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(picked.joined(separator: ", ")) FROM threads WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        var row: [String: String] = [:]
        for (i, name) in picked.enumerated() where sqlite3_column_type(statement, Int32(i)) == SQLITE_TEXT {
            row[name] = String(cString: sqlite3_column_text(statement, Int32(i)))
        }
        let title = [row["name"], row["title"], row["first_user_message"]].lazy.compactMap { $0.flatMap(AgentPolicy.title) }.first ?? "Untitled"
        return (title, row["cwd"].flatMap { $0.isEmpty ? nil : $0 }, AgentPolicy.codexSubagent(source: row["source"]))
    }

    /// The database, read-only. Its WAL needs a `-shm` beside it that a reader may have to make; where
    /// it can't (a sandboxed test host while Codex is not running), it is read as immutable instead.
    private static func open(_ path: String) -> OpaquePointer? {
        for (name, flags) in [(path, SQLITE_OPEN_READONLY),
                              ("file:\(path)?immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)] {
            var db: OpaquePointer?
            if sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK, let db,
               sqlite3_exec(db, "SELECT 1 FROM threads LIMIT 1", nil, nil, nil) == SQLITE_OK {
                sqlite3_busy_timeout(db, 500)
                return db
            }
            sqlite3_close(db)
        }
        return nil
    }

    private func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var out = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { out.insert(String(cString: name)) }
        }
        return out
    }

    /// The newest rate limits Codex recorded: the last `token_count` with `rate_limits` in its most
    /// recently written session files (the five newest at most).
    func usage() -> AgentUsage? {
        let sessions = root.appendingPathComponent("sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys) else { return nil }
        var files: [(url: URL, modified: Double, size: Int)] = []
        for case let url as URL in walk where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let d = v.contentModificationDate, let size = v.fileSize else { continue }
            files.append((url, d.timeIntervalSince1970, size))
        }
        files.sort { $0.modified > $1.modified }
        if let newest = files.first, let seen = usageSeen, seen.path == newest.url.path, seen.modified == newest.modified {
            return seen.usage
        }
        var found: AgentUsage?
        for f in files.prefix(5) {
            let start = max(0, f.size - 256 * 1024)
            guard let data = readBytes(f.url, offset: UInt64(start), count: f.size - start) else { continue }
            if let u = AgentPolicy.lines(data, cutStart: start > 0, cutEnd: false).reversed().lazy.compactMap(AgentPolicy.codexUsage).first {
                found = u
                break
            }
        }
        if let newest = files.first { usageSeen = (newest.url.path, newest.modified, found) }
        return found
    }
}

/// Claude's remaining usage, from Anthropic's usage endpoint with Claude Code's own sign-in (its
/// Keychain item; macOS asks once). Never refreshed here: a refresh would replace Claude Code's own
/// sign-in and sign it out, so an expired one waits for Claude Code to renew it. An answer is kept a
/// minute (a failure 15 s), so many queries make one call. Used on the agents' queue (AgentsFeature) alone.
final class ClaudeUsage: @unchecked Sendable {
    let home: URL
    private var last: (at: Double, usage: AgentUsage?, problem: String?)?
    private let queue: DispatchQueue

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    init(home: URL, queue: DispatchQueue) { self.home = home; self.queue = queue }

    /// The usage or why there is none; `done` runs on the queue.
    func read(now: Double, done: @escaping (AgentUsage?, String?) -> Void) {
        if let last, now - last.at < (last.usage != nil ? 60 : 15) { return done(last.usage, last.problem) }
        let signIn: AgentPolicy.SignIn
        switch credentials() {
        case .found(let data): signIn = AgentPolicy.claudeSignIn(data, now: now)
        case .missing: signIn = .signedOut
        case .refused: return finish(now, nil, AgentProvider.keychain, done)
        }
        guard case .token(let token, let plan) = signIn else {
            return finish(now, nil, signIn == .expired ? AgentProvider.expired : AgentProvider.signedOut, done)
        }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 { return self.finish(now, nil, AgentProvider.expired, done) }
                guard status == 200, let data, let usage = AgentPolicy.claudeUsage(data, plan: plan, now: now) else {
                    return self.finish(now, nil, AgentProvider.unavailable, done)
                }
                self.finish(now, usage, nil, done)
            }
        }.resume()
    }

    private func finish(_ now: Double, _ usage: AgentUsage?, _ problem: String?, _ done: (AgentUsage?, String?) -> Void) {
        if problem != last?.problem, let problem { print("Agents: Claude's usage is not available (\(problem)).") }
        last = (now, usage, problem)
        done(usage, problem)
    }

    private enum Credentials { case found(Data), missing, refused }

    /// Claude Code's sign-in: its Keychain item, else its file (`~/.claude/.credentials.json`).
    private func credentials() -> Credentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return .found(data) }
        if status != errSecItemNotFound { return .refused }
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")) { return .found(data) }
        return .missing
    }
}
