import CoreServices
import Foundation
import StreamProtocol

/// Notices an agent's turn ending (docs/background-plan.md), for the notifications: FSEvents on Claude
/// Code's transcripts (`~/.claude/projects/<folder>/<session>.jsonl`) and Codex's session files
/// (`~/.codex/sessions/…/rollout-*.jsonl`), each read from where it was last read, its new whole lines
/// to AgentPolicy's `claudeTurnEnds` and `codexTurnEnds`.
///
/// - Runs only between `start` and `stop`: AgentsFeature starts it while some device wants agent
///   notifications and stops it when none does, so a Mac nobody is connected to watches nothing.
/// - Every file already there when the watch starts is noted at its size then, so no turn from before
///   ever notifies; a file made since is read from its start.
/// - One finish per session within `AgentPolicy.finishQuiet`; a Codex sub-agent's thread never.
/// - Only what a list shows goes into the event: the session's title and its folder's name.
///
/// On the agents' queue (AgentsFeature), which the FSEvents stream delivers to.
final class AgentWatch: @unchecked Sendable {
    private let queue: DispatchQueue
    private let claude: ClaudeReader
    private let codex: CodexReader
    private let claudeRoot: URL
    private let codexRoot: URL
    private var stream: FSEventStreamRef?
    /// Where each file was last read to.
    private var offsets: [String: UInt64] = [:]
    /// Each session's last finish ("claude:<id>"), for the quiet time.
    private var lastFinish: [String: Double] = [:]

    /// A turn ended. On the queue.
    var onFinish: ((AgentEvent) -> Void)?

    /// The most a file's new bytes are read at once; past it, only its last part.
    static let readCap = 4 << 20

    init(home: URL, claude: ClaudeReader, codex: CodexReader, queue: DispatchQueue) {
        self.queue = queue
        self.claude = claude
        self.codex = codex
        claudeRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    var running: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        let roots = [claudeRoot, codexRoot].map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        offsets = baseline()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<AgentWatch>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watch.changed(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        print("Agents: watching for finished turns.")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        offsets = [:]
        lastFinish = [:]
        print("Agents: no longer watching.")
    }

    // MARK: On the queue

    /// Every transcript and session file there now, at its size.
    private func baseline() -> [String: UInt64] {
        let fm = FileManager.default
        var out: [String: UInt64] = [:]
        func note(_ url: URL) {
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber { out[url.path] = size.uint64Value }
        }
        for dir in (try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
                note(file)
            }
        }
        if let files = fm.enumerator(at: codexRoot, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "jsonl" { note(file) }
        }
        return out
    }

    private func changed(_ paths: [String]) {
        guard stream != nil else { return }
        for path in Set(paths) where path.hasSuffix(".jsonl") {
            let url = URL(fileURLWithPath: path)
            let parent = url.deletingLastPathComponent()
            if parent.deletingLastPathComponent().path == claudeRoot.path {
                // A session's own transcript: projects/<folder>/<session>.jsonl (a sub-agent's are deeper).
                read(url) { self.claudeEnded(url, $0) }
            } else if path.hasPrefix(codexRoot.path + "/"), AgentPolicy.codexThread(fileName: url.lastPathComponent) != nil {
                read(url) { self.codexEnded(url, $0) }
            }
        }
    }

    /// The file's new whole lines since it was last read.
    private func read(_ url: URL, _ handle: ([String]) -> Void) {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { offsets[path] = nil; return }
        // Not noted at the start: made since, so read from its start.
        var from = offsets[path] ?? 0
        if size < from { offsets[path] = size; return }       // cut short: start again from its end
        guard size > from else { return }
        if size - from > UInt64(Self.readCap) { from = size - UInt64(Self.readCap) }
        guard let handleFile = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handleFile.close() }
        try? handleFile.seek(toOffset: from)
        guard let data = try? handleFile.read(upToCount: Int(size - from)) else { return }
        let (lines, consumed) = AgentPolicy.complete(data)
        offsets[path] = from + UInt64(consumed)
        if !lines.isEmpty { handle(lines) }
    }

    private func claudeEnded(_ url: URL, _ lines: [String]) {
        guard !AgentPolicy.claudeTurnEnds(lines).isEmpty else { return }
        let id = url.deletingPathExtension().lastPathComponent
        guard quiet("claude:\(id)") else { return }
        let session = claude.session(at: url)
        finish(AgentEvent(provider: AgentProvider.claude, session: id, title: session?.title ?? "Untitled",
                          project: session?.project.map { ($0 as NSString).lastPathComponent }, kind: AgentEvent.finished,
                          at: Date().timeIntervalSince1970))
    }

    private func codexEnded(_ url: URL, _ lines: [String]) {
        guard !AgentPolicy.codexTurnEnds(lines).isEmpty, let id = AgentPolicy.codexThread(fileName: url.lastPathComponent) else { return }
        let thread = codex.thread(id)
        guard thread?.subagent != true, quiet("codex:\(id)") else { return }
        finish(AgentEvent(provider: AgentProvider.codex, session: id, title: thread?.title ?? "Untitled",
                          project: thread?.project.map { ($0 as NSString).lastPathComponent }, kind: AgentEvent.finished,
                          at: Date().timeIntervalSince1970))
    }

    /// The session has not finished within the quiet time; marks it finished now.
    private func quiet(_ key: String) -> Bool {
        let now = Date().timeIntervalSince1970
        if let last = lastFinish[key], now - last < AgentPolicy.finishQuiet { return false }
        lastFinish[key] = now
        return true
    }

    private func finish(_ event: AgentEvent) {
        onFinish?(event)
    }
}
