import Foundation

/// State of a Claude Code session at this moment, parsed from its session file.
public struct Session: Equatable, Sendable {
    public var pid: Int32
    /// Process start time (UTC, second precision): used with pid to identify process and prevent pid reuse
    public var processStart: Date
    /// Matches turn file written by mod; changes after /clear. Validated as UUID: will be interpolated into file paths
    public var sessionId: String
    /// Absolute path to working directory
    public var cwd: String
    public var state: AgentState
    /// Timestamp when this state was entered
    public var stateSince: Date
}

/// Agent state (docs/agent-integration.md "States")
public enum AgentState: Equatable, Sendable {
    case working
    case stopped
    case needsYou(Need)

    /// Category of required intervention: determines whether Pip shows question or approval (docs/mascot.md §2)
    public enum Need: Sendable {
        case question
        case approval
    }
}

/// Reasons parsing session file failed: App counts and skips without overwriting file (CLAUDE.md Principle 5)
public enum SessionFileError: Error, Equatable {
    case unknownStatus(String)
    case badSessionId(String)
}

/// Answers: whether a ~/.claude/sessions/<pid>.json is a target session, and its current state.
/// Extracts only fields required for judgment and display; does not read files or query processes directly.
/// @see docs/agent-integration.md "Observations" (Claude Code 2.1.296)
public enum SessionFile {
    /// If not an interactive claude run in terminal (claude -p, SDK, VS Code, background sessions, etc.),
    /// or session has just started and not written status yet, returns nil without further checks.
    public static func parse(_ data: Data) throws -> Session? {
        let gate = try JSONDecoder().decode(Gate.self, from: data)
        guard gate.kind == "interactive", gate.entrypoint == "cli", gate.status != nil else { return nil }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard UUID(uuidString: raw.sessionId) != nil else { throw SessionFileError.badSessionId(raw.sessionId) }
        return Session(pid: raw.pid, processStart: try Date(raw.procStart, strategy: lstart),
                       sessionId: raw.sessionId, cwd: raw.cwd,
                       state: try state(raw.status, waitingFor: raw.waitingFor), stateSince: Date(timeIntervalSince1970: raw.statusUpdatedAt / 1000))
    }

    /// claude -p has kind == "interactive" as well, with entrypoint == "sdk-cli" ("Observations" 1);
    /// First file written by session lacks status and statusUpdatedAt, filled in shortly after ("Observations" 5)
    private struct Gate: Decodable {
        var kind: String?
        var entrypoint: String?
        var status: String?
    }

    private struct Raw: Decodable {
        var pid: Int32
        var procStart: String
        var sessionId: String
        var cwd: String
        var status: String
        var waitingFor: String?
        var statusUpdatedAt: Double
    }

    private static func state(_ status: String, waitingFor: String?) throws -> AgentState {
        switch status {
        case "busy": return .working
        // "shell": idle, but background shell command is running (docs/agent-integration.md "Observations" 6)
        case "idle", "shell": return .stopped
        case "waiting": return .needsYou(approvalKinds.contains(waitingFor ?? "") ? .approval : .question)
        default: throw SessionFileError.unknownStatus(status)
        }
    }

    /// Claude Code classifies these waitingFor values as permission; "input needed", "dialog open", and unseen values default to question
    private static let approvalKinds: Set = ["permission prompt", "sandbox request", "worker request", "goal proposal"]

    /// procStart is output of LC_ALL=C TZ=UTC ps -o lstart=, e.g. "Thu Oct 29 17:54:51 2026"
    private static let lstart = Date.ParseStrategy(
        format: "\(weekday: .abbreviated) \(month: .abbreviated) \(day: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) \(year: .defaultDigits)",
        locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
}
