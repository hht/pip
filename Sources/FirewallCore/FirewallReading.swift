import Foundation

/// Answers: how the App describes the current firewall condition—not installed, off, trial, on, or unknown; and flags problems requiring attention (docs/firewall.md §2, §4).
/// App trusts fresh status summaries only: trial/on summaries unupdated for 30s (3 rounds) evaluate as unknown; off ignores freshness.
/// Only on with production rules, all checks passed, and no failed steps evaluates as "Protected". Pure value types.
public enum FirewallReading: Equatable, Sendable {
    case notInstalled
    case off(problem: Problem?)
    /// `endsAt` is wall-clock time for countdown display only
    case trial(endsAt: Date?, problem: Problem?)
    case on(problem: Problem?)
    /// Indeterminate state: disable or uninstall both remain available
    case unknown(Problem)

    public enum Problem: Equatable, Sendable {
        /// Installed, but summary absent: initial round pending or partial cleanup
        case noSummary
        case unreadable
        /// Summary unupdated for too long: daemon uninstalled, crashed, or rescue script recently ran
        case stale
        /// Firewall state file unreadable, daemon treated as off (flushed rules); reinstall required
        case stateUnreadable
        /// Test rules installed: blocks traffic to test table only
        case testRules
        /// Rule reload failed this round: anchor lacks current rules (retried next round)
        case rulesNotLoaded
        /// Tunnel interface missing: Clash TUN inactive or mismatched interface name (docs/firewall.md §5)
        case tunnelMissing
        case checkFailed
        /// Failed pf action this round (retried next round): rules may linger when off
        case failedSteps
    }

    /// Result of reading status summary
    public enum Summary: Sendable {
        case missing, unreadable
        case read(FirewallStatus)
    }

    /// Daemon runs every 10s, untrusted if unupdated after 3 rounds
    public static let freshness: TimeInterval = 30

    /// `installed`: LaunchDaemon or helper present. Retained summary without install treated as installed for visibility
    public init(installed: Bool, summary: Summary, now: Date) {
        let status: FirewallStatus
        switch summary {
        case .missing: self = installed ? .unknown(.noSummary) : .notInstalled; return
        case .unreadable: self = .unknown(.unreadable); return
        case .read(let s): status = s
        }
        let failed: Problem? = status.failedSteps.isEmpty ? nil : .failedSteps
        if status.mode == .off { self = .off(problem: status.failedSteps.contains(.flush) ? .failedSteps : nil); return }
        if status.mode == .stateUnreadable { self = .off(problem: .stateUnreadable); return }
        guard abs(now.timeIntervalSince(status.checkedAt)) <= Self.freshness else { self = .unknown(.stale); return }
        let problem: Problem? = switch (status.scope, status.check) {
        case (nil, _): .rulesNotLoaded
        case (.testTable?, _): .testRules
        case (_, let check?) where !check.tunnelPresent && check.passedApartFromTunnel: .tunnelMissing
        case (_, let check?) where check.passed: failed
        default: .checkFailed
        }
        self = status.mode == .trial ? .trial(endsAt: status.trialEndsAt, problem: problem) : .on(problem: problem)
    }

    /// Toggle displays as on: trial, on, and unknown (allows clicking off). Missing summary also counts as unknown
    public var switchedOn: Bool {
        switch self {
        case .notInstalled, .off: false
        case .trial, .on, .unknown: true
        }
    }

    /// Whether Keep is permitted: permitted only when trial is normal. Missing interface disables Keep
    public var canKeep: Bool {
        switch self {
        case .trial(_, nil), .trial(_, .testRules?): true
        default: false
        }
    }

    /// Settled check: summary written after command began, or 3-round timeout elapsed
    public static func settled(checkedAt: Date?, commandStarted: Date, now: Date) -> Bool {
        checkedAt.map { $0 > commandStarted } ?? false || now.timeIntervalSince(commandStarted) > freshness
    }
}
