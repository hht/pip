import Foundation

/// Answers: format of the firewall state file `firewall.state` and interpretation of restored values (docs/firewall.md §4).
/// Rescue script `scripts/firewall-rescue.sh` reads `token` (numeric string) and `bootSession` using plutil; any renaming or type changes must be synced across both.
/// Unaware of file locations or write mechanisms.
extension FirewallState {
    public static let fileName = "firewall.state"

    /// Result of reading the firewall state file. Separates unreadable (corrupt/mismatched format) from missing: missing is normal (fresh install); corrupt is reported without overwriting original.
    public enum Restored: Equatable, Sendable {
        case valid(FirewallState)
        case missing
        case unreadable
    }

    /// `data == nil` indicates missing file
    public static func restore(from data: Data?) -> Restored {
        guard let data else { return .missing }
        guard let f = try? JSONDecoder().decode(Fields.self, from: data) else { return .unreadable }
        var s = FirewallState(bootSession: f.bootSession)
        switch (f.mode ?? "off", f.deadline) {
        case ("off", _): s.mode = .off
        case ("trial", let deadline?): s.mode = .trial(deadline: MonotonicTime(milliseconds: deadline))
        case ("on", _): s.mode = .on
        default: return .unreadable
        }
        switch (f.token, f.tokenUnknown ?? false) {
        case (nil, false): s.reference = nil
        case (nil, true): s.reference = .unknownToken
        case (let token?, false) where !token.isEmpty && token.allSatisfy({ ("0"..."9").contains($0) }):
            s.reference = .held(token: token)
        default: return .unreadable
        }
        s.loadedRules = f.loadedRules.map(FirewallRules.init(loaded:))
        s.lastEvaluations = f.lastEvaluations
        return .valid(s)
    }

    public func encoded() throws -> Data {
        var f = Fields(bootSession: bootSession, loadedRules: loadedRules?.text, lastEvaluations: lastEvaluations)
        switch mode {
        case .off: f.mode = "off"
        case .trial(let deadline): (f.mode, f.deadline) = ("trial", deadline.milliseconds)
        case .on: f.mode = "on"
        }
        switch reference {
        case nil: break
        case .held(let token): f.token = token
        case .unknownToken: f.tokenUnknown = true
        }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(f)
    }

    /// Fields in the file: missing fields use default values, extra fields are ignored (CLAUDE.md "Configuration and state files")
    private struct Fields: Codable {
        var mode: String?
        /// Trial run deadline, monotonic clock milliseconds
        var deadline: Int64?
        var bootSession: String?
        var token: String?
        var tokenUnknown: Bool?
        var loadedRules: String?
        var lastEvaluations: UInt64?
    }
}

extension FirewallRules {
    /// "Last loaded rules" recorded in the firewall state file: only used to compare with current desired rules, not reloaded into pf
    init(loaded text: String) { self.text = text }
}
