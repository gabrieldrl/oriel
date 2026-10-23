import Foundation

/// The coding agents on the Mac, Claude Code and Codex (kinds 53 and 54; docs/agents-plan.md):
/// whether each is installed, its remaining usage and its sessions. Only what a list shows ever goes:
/// titles, folders, times, models and token counts, never a transcript's contents.
///
/// - On the background link (Background.swift) only. A device asks with a kind 54 (`AgentQuery`) and
///   gets one kind 53 (`AgentReport`) carrying its token.
///
/// HostSettings.swift's rules apply: JSON, every field optional where it may be missing, fields
/// added later optional, `id`s compared as strings so a later agent needs no new case.
public struct AgentQuery: Codable, Hashable, Sendable {
    /// Increasing per device process; the report carries it back (`answering`).
    public var token: Int?
    /// Sessions active in the last this many days; nil, every one.
    public var days: Int?
    /// At most this many sessions per agent, the newest first (`AgentReport.maxSessions` at most).
    public var limit: Int?
    /// `AgentProvider.id`s; nil, every one.
    public var providers: [String]?
    /// Read the usage too (Claude's asks Anthropic, at most once a minute on the Mac).
    public var usage: Bool?

    public init(token: Int? = nil, days: Int? = nil, limit: Int? = nil, providers: [String]? = nil, usage: Bool? = nil) {
        self.token = token; self.days = days; self.limit = limit; self.providers = providers; self.usage = usage
    }
}

/// The answer to one query.
public struct AgentReport: Codable, Hashable, Sendable {
    /// The query's token.
    public var answering: Int?
    /// When the Mac made it (seconds since 1970).
    public var at: Double
    public var providers: [AgentProvider]

    public init(answering: Int?, at: Double, providers: [AgentProvider]) {
        self.answering = answering; self.at = at; self.providers = providers
    }

    /// The most sessions per agent in one report.
    public static let maxSessions = 500
}

/// One agent on the Mac.
public struct AgentProvider: Codable, Hashable, Sendable, Identifiable {
    /// `claude`, `codex`.
    public var id: String
    /// "Claude", "Codex".
    public var name: String
    /// Its command-line tool or its data was found.
    public var installed: Bool
    /// Its tool's version, "2.1.296".
    public var version: String?
    public var usage: AgentUsage?
    /// Why there is no usage: `signedOut`, `expired`, `keychain`, `unavailable`, `noRecord`.
    public var usageProblem: String?
    /// The newest first.
    public var sessions: [AgentSession]
    /// More sessions matched than were sent.
    public var more: Bool?

    public init(id: String, name: String, installed: Bool, version: String? = nil, usage: AgentUsage? = nil,
                usageProblem: String? = nil, sessions: [AgentSession] = [], more: Bool? = nil) {
        self.id = id; self.name = name; self.installed = installed; self.version = version
        self.usage = usage; self.usageProblem = usageProblem; self.sessions = sessions; self.more = more
    }

    public static let claude = "claude", codex = "codex"
    /// `usageProblem`s.
    public static let signedOut = "signedOut", expired = "expired", keychain = "keychain",
                      unavailable = "unavailable", noRecord = "noRecord"
}

/// An agent's remaining usage: its limits as its service reports them.
public struct AgentUsage: Codable, Hashable, Sendable {
    public var limits: [AgentLimit]
    /// "max", "pro".
    public var plan: String?
    /// When these figures were true (seconds since 1970): now for Claude's, the session file's
    /// last turn for Codex's.
    public var asOf: Double
    /// Codex's credits left, as it reports them ("62427.63").
    public var credits: String?

    public init(limits: [AgentLimit], plan: String? = nil, asOf: Double, credits: String? = nil) {
        self.limits = limits; self.plan = plan; self.asOf = asOf; self.credits = credits
    }
}

/// One limit: how much of it is used, and when it starts again.
public struct AgentLimit: Codable, Hashable, Sendable, Identifiable {
    /// `five_hour`, `seven_day`, `seven_day_opus`, `primary`, `secondary`.
    public var id: String
    /// "5-hour", "Weekly", "Weekly Opus".
    public var name: String
    /// 0…100.
    public var usedPercent: Double
    /// Seconds since 1970.
    public var resetsAt: Double?
    public var windowMinutes: Int?

    public init(id: String, name: String, usedPercent: Double, resetsAt: Double? = nil, windowMinutes: Int? = nil) {
        self.id = id; self.name = name; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.windowMinutes = windowMinutes
    }
}

/// One session of an agent.
public struct AgentSession: Codable, Hashable, Sendable, Identifiable {
    /// The agent's own id for it.
    public var id: String
    /// `AgentProvider.id`.
    public var provider: String
    /// Its name, else its first prompt (one line, at most `AgentSession.titleLength` characters).
    public var title: String
    /// The folder it runs in, "/Users/me/Code/sill".
    public var project: String?
    public var branch: String?
    public var model: String?
    /// Seconds since 1970.
    public var updatedAt: Double
    public var createdAt: Double?
    /// Running now.
    public var running: Bool?
    public var tokens: Int?

    public init(id: String, provider: String, title: String, project: String? = nil, branch: String? = nil,
                model: String? = nil, updatedAt: Double, createdAt: Double? = nil, running: Bool? = nil, tokens: Int? = nil) {
        self.id = id; self.provider = provider; self.title = title; self.project = project; self.branch = branch
        self.model = model; self.updatedAt = updatedAt; self.createdAt = createdAt; self.running = running; self.tokens = tokens
    }

    public static let titleLength = 120
}
