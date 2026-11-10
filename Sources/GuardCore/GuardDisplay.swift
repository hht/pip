import Foundation

/// Answers: what egress guard discovered in the latest round, and what App should display.
/// Calculated from single-round verdict and observation, agnostic of probe mechanics (GuardProbes `GuardMonitor`) and rendering (NotchCore `GuardPresentation`).
/// IP appears in `egressIP` only (fully displayed in UI), never written to logs (CLAUDE.md "logs never record IP").
public struct GuardDisplay: Equatable, Sendable {
    public var verdict: Verdict
    /// Timestamp when check completed; `nil` if first round incomplete after launch (`checking`)
    public var checkedAt: Date?
    /// Present only when verdict is unknown and a round has finished (see `UnknownReason`)
    public var unknownReason: UnknownReason?
    /// Present only when verdict is violated: round when this violation began (see `EgressGuard.violatedSince`). App uses it to record which incident user dismissed.
    public var violatedSince: Date?
    /// Egress IP observed in this round (see `Observation.shownEgressIP`). `nil` if not obtained, never carrying over previous round; sticky violated also reports this round
    public var egressIP: String?

    /// App just launched, first round incomplete
    public static let checking = GuardDisplay(verdict: .unknown)

    public init(verdict: Verdict, checkedAt: Date? = nil, unknownReason: UnknownReason? = nil, violatedSince: Date? = nil, egressIP: String? = nil) {
        self.verdict = verdict
        self.checkedAt = checkedAt
        self.unknownReason = unknownReason
        self.violatedSince = violatedSince
        self.egressIP = egressIP
    }

    /// Single round result. `networkPath` is round snapshot (`nil` if unavailable), used solely for `unknownReason`;
    /// `violatedSince` forwards `EgressGuard.violatedSince`, ignored if verdict is not violated
    public init(verdict: Verdict, observation o: Observation, allowlist: Set<IPv4>, networkPath: NetworkPath?,
                violatedSince: Date?, checkedAt: Date) {
        self.init(verdict: verdict, checkedAt: checkedAt,
                  unknownReason: UnknownReason.decide(verdict: verdict, path: networkPath),
                  violatedSince: verdict == .violated ? violatedSince : nil,
                  egressIP: o.shownEgressIP(allowlist: allowlist)?.description)
    }
}

/// Answers: which directory stores App configuration, plugins, and CLI tool files. Path computation only, touches no files.
public enum GuardPaths {
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Notchkeeper", isDirectory: true)
    public static let configFile = directory.appendingPathComponent("config.json")
}
