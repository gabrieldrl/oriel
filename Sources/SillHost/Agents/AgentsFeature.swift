import Foundation
import StreamProtocol

/// The Mac's coding agents as a background feature (docs/background-plan.md, docs/agents-plan.md):
///
/// - **Reports.** A link's kind 54 (AgentQuery) is answered once with a kind 53 (AgentReport): each
///   agent installed or not, its usage, its sessions. The readers keep what they read (ClaudeReader's
///   summaries, Claude's usage for a minute), so the next query reads only what changed.
/// - **Finished turns.** While some device wants agent notifications, AgentWatch watches; each finish
///   goes to every such device as a push, and as a kind 58 on every live link.
///
/// Everything here runs on one queue, the agents' own, which the readers and the watch share. A
/// synthetic host reads this Mac's agents as Sill.app does but never its Keychain: Claude's usage
/// there is `unavailable`.
///
/// TEST ONLY, a synthetic host only: `SILL_TEST_AGENTS_HOME=<dir>` reads `<dir>/.claude` and
/// `<dir>/.codex` in place of this user's, so a test writes the transcripts it watches.
final class AgentsFeature: BackgroundFeature, @unchecked Sendable {
    private let queue = DispatchQueue(label: "sill.agents", qos: .utility)
    private weak var background: BackgroundServer?
    private let synthetic: Bool
    private let claude: ClaudeReader
    private let codex: CodexReader
    private let claudeUsage: ClaudeUsage
    private let watch: AgentWatch

    init(background: BackgroundServer, synthetic: Bool) {
        self.background = background
        self.synthetic = synthetic
        var home = FileManager.default.homeDirectoryForCurrentUser
        if synthetic, let dir = ProcessInfo.processInfo.environment["SILL_TEST_AGENTS_HOME"], !dir.isEmpty {
            home = URL(fileURLWithPath: dir, isDirectory: true)
            print("Test agents: reading \(dir) (SILL_TEST_AGENTS_HOME).")
        }
        claude = ClaudeReader(home: home)
        codex = CodexReader(home: home)
        claudeUsage = ClaudeUsage(home: home, queue: queue)
        watch = AgentWatch(home: home, claude: claude, codex: codex, queue: queue)
        watch.onFinish = { [weak self] in self?.finished($0) }
    }

    // MARK: BackgroundFeature (on the background server's queue)

    func registrationsChanged(_ registry: BackgroundPolicy.Registry) {
        let wanted = BackgroundPolicy.watchesAgents(registry)
        queue.async { [watch] in
            if wanted { watch.start() } else { watch.stop() }
        }
    }

    func received(_ kind: StreamMessageKind, _ payload: Data, from link: BackgroundServer.Link) -> Bool {
        guard kind == .agentQuery else { return false }
        guard let query = Wire.decode(AgentQuery.self, from: payload) else { return true }
        report(query) { report in link.send(.agents, Wire.encode(report)) }
        return true
    }

    // MARK: On the agents' queue

    private func finished(_ event: AgentEvent) {
        guard let background else { return }
        let agent = event.provider == AgentProvider.codex ? "Codex" : "Claude"
        let payload = BackgroundPolicy.agentPayload(event, agent: agent, macName: background.macName, macID: background.macID)
        print("Agents: \(agent) finished a turn\(event.project.map { " in \($0)" } ?? "").")
        background.push(payload, collapse: "\(event.provider):\(event.session)") { $0.features.agentsNotify == true }
        background.broadcast(.agentEvent, Wire.encode(event)) { $0.features.agentsNotify == true }
    }

    /// One query's report; `done` on the agents' queue.
    private func report(_ query: AgentQuery, done: @escaping (AgentReport) -> Void) {
        let (claude, codex, claudeUsage, synthetic) = (self.claude, self.codex, self.claudeUsage, self.synthetic)
        queue.async {
            let now = Date().timeIntervalSince1970
            let wanted = query.providers.map(Set.init)
            let cutoff = AgentPolicy.cutoff(days: query.days, now: now)
            let limit = min(max(query.limit ?? AgentPolicy.defaultLimit, 1), AgentReport.maxSessions)
            var providers: [AgentProvider] = []
            var claudeAt: Int?

            if wanted?.contains(AgentProvider.claude) ?? true {
                var p = AgentProvider(id: AgentProvider.claude, name: "Claude", installed: claude.installed,
                                      version: claude.tool.flatMap(AgentTools.version))
                if p.installed {
                    let picked = AgentPolicy.pick(claude.sessions(since: cutoff), days: query.days, limit: limit, now: now)
                    p.sessions = picked.sessions
                    p.more = picked.more ? true : nil
                }
                claudeAt = providers.count
                providers.append(p)
            }
            if wanted?.contains(AgentProvider.codex) ?? true {
                var p = AgentProvider(id: AgentProvider.codex, name: "Codex", installed: codex.installed,
                                      version: codex.tool.flatMap(AgentTools.version))
                if p.installed {
                    let picked = codex.sessions(since: cutoff, limit: limit, now: now)
                    p.sessions = picked.sessions
                    p.more = picked.more ? true : nil
                    if query.usage == true {
                        p.usage = codex.usage()
                        if p.usage == nil { p.usageProblem = AgentProvider.noRecord }
                    }
                }
                providers.append(p)
            }

            let send = { (providers: [AgentProvider]) in done(AgentReport(answering: query.token, at: now, providers: providers)) }
            guard query.usage == true, let i = claudeAt, providers[i].installed else { return send(providers) }
            guard !synthetic else {
                providers[i].usageProblem = AgentProvider.unavailable
                return send(providers)
            }
            claudeUsage.read(now: now) { usage, problem in
                providers[i].usage = usage
                providers[i].usageProblem = problem
                send(providers)
            }
        }
    }
}
