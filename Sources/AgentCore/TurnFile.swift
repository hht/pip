import Foundation

/// Latest finished main turn reported by mod for a session (docs/agent-integration.md "Turn files")
public struct TurnReport: Equatable, Sendable {
    /// Validated as UUID: will be interpolated into file paths
    public var sessionId: String
    /// nil: no turn has completed yet
    public var ended: EndedTurn?

    public init(sessionId: String, ended: EndedTurn?) {
        self.sessionId = sessionId
        self.ended = ended
    }
}

public struct EndedTurn: Equatable, Sendable {
    public var turnId: String
    public var outcome: TurnOutcome
    /// Background agents still running at completion time
    public var backgroundAgents: Int
    /// Timestamp of completion: earlier than App watching start is considered mid-session takeover, skipping notifications
    public var at: Date

    public init(turnId: String, outcome: TurnOutcome, backgroundAgents: Int, at: Date) {
        self.turnId = turnId
        self.outcome = outcome
        self.backgroundAgents = backgroundAgents
        self.at = at
    }
}

/// How the turn ended (docs/agent-integration.md "How turns end")
public enum TurnOutcome: Sendable {
    case done
    case failed
    /// You pressed Esc, or rejected in approval prompt
    case canceled
}

/// Reasons parsing turn file failed: App counts and skips without overwriting file (CLAUDE.md Principle 5)
public enum TurnFileError: Error, Equatable {
    case unknownReason(String)
    case badSessionId(String)
}

/// Answers: which turn most recently finished and how it finished, per turns/<sessionId>.json written by Pip mod.
/// Does not read files; unaware of sessions, processes, or cards.
public enum TurnFile {
    public static func parse(_ data: Data) throws -> TurnReport {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard UUID(uuidString: raw.sessionId) != nil else { throw TurnFileError.badSessionId(raw.sessionId) }
        return TurnReport(sessionId: raw.sessionId, ended: try raw.ended.map { e in
            EndedTurn(turnId: e.turnId, outcome: try outcome(e.reason, lastStop: e.lastStop), backgroundAgents: e.backgroundAgents,
                      at: Date(timeIntervalSince1970: e.at / 1000))
        })
    }

    private struct Raw: Decodable {
        var sessionId: String
        var ended: Ended?

        struct Ended: Decodable {
            var turnId: String
            var reason: String
            var lastStop: String?
            var backgroundAgents: Int
            /// Epoch milliseconds (mod's $.clock.now())
            var at: Double
        }
    }

    /// Values of reason match TurnCompleteReason in Claude Code 2.1.296. When rejected in approval prompt, reason is still answer,
    /// but lastStop stopped at tool_use: no further model requests after tool result (empirically verified)
    private static func outcome(_ reason: String, lastStop: String?) throws -> TurnOutcome {
        switch reason {
        case "answer": return lastStop == "tool_use" ? .canceled : .done
        case "aborted": return .canceled
        case "error", "refusal": return .failed
        default: throw TurnFileError.unknownReason(reason)
        }
    }
}
