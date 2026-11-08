import Foundation

/// Answers: what the firewall state looks like to the daemon in this round, formatted for the App (`firewall-status.json`, root 0644, docs/firewall.md §4).
/// App only reads this, with no resident privileged code; freshness and "protected" status are judged by reader via `checkedAt`. Unaware of file locations or write mechanisms.
public struct FirewallStatus: Codable, Equatable, Sendable {
    public static let fileName = "firewall-status.json"

    public enum Mode: String, Codable, Sendable {
        case off, trial, on
        /// Firewall state file unreadable: treated as off (flush rules, do not overwrite state file), reported as error
        case stateUnreadable
    }

    public var mode: Mode
    /// Loaded rules scope; `nil` if unknown. Only `.everyone` represents real blocking (test rules only block traffic to test tables); App uses this to determine if "Protected" can be displayed.
    public var scope: FirewallRules.Scope?
    /// Trial end wall-clock time (for UI countdown only; true deadline uses monotonic clock, see `FirewallState`)
    public var trialEndsAt: Date?
    /// Verified only when enabled
    public var check: FirewallCheck?
    /// pf steps that failed in this round; retried in the next round
    public var failedSteps: [PFStep]
    public var checkedAt: Date

    public init(mode: Mode, scope: FirewallRules.Scope?, trialEndsAt: Date? = nil, check: FirewallCheck? = nil,
                failedSteps: [PFStep] = [], checkedAt: Date) {
        self.mode = mode
        self.scope = scope
        self.trialEndsAt = trialEndsAt
        self.check = check
        self.failedSteps = failedSteps
        self.checkedAt = checkedAt
    }

    /// Missing fields use defaults, extra fields are ignored (CLAUDE.md "Configuration and state files"); fails if `checkedAt` missing: freshness cannot be evaluated without it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .off
        scope = try c.decodeIfPresent(FirewallRules.Scope.self, forKey: .scope)
        trialEndsAt = try c.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        check = try c.decodeIfPresent(FirewallCheck.self, forKey: .check)
        failedSteps = try c.decodeIfPresent([PFStep].self, forKey: .failedSteps) ?? []
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> FirewallStatus {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(FirewallStatus.self, from: data)
    }
}
