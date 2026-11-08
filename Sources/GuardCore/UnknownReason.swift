/// Answers: when a round evaluates as unknown, is it because there is no network (offline), or network is up but probes failed to return a result.
/// Used only for unknown: healthy, egressMismatch, and violated never carry a reason. UI colors do not inspect it (all unknown share gray ring),
/// used only for selecting text (docs/egress-guard.md "How It Is Rendered").
public enum UnknownReason: String, Codable, Sendable, Equatable {
    /// No satisfied non-utun physical interface, or no default route
    case offline
    /// Network is satisfied (or snapshot unavailable), but routes / Clash / egress probes returned no evaluable result
    case probeFailed

    /// Offline takes priority: when disconnected, probes necessarily fail as well. Missing snapshot falls back to probeFailed.
    /// Does not require inspecting round observations: unknown itself implies probe failure; network snapshot determines subtype.
    public static func decide(verdict: Verdict, path: NetworkPath?) -> UnknownReason? {
        guard verdict == .unknown else { return nil }
        if let path, !path.isUp { return .offline }
        return .probeFailed
    }
}

/// Answers: does the machine currently have a physical network route not traversing TUN? Read-only snapshot from Network.framework (GuardProbes).
/// Stores two booleans only, never interface names or addresses (CLAUDE.md "logs never record IP").
public struct NetworkPath: Sendable, Equatable {
    /// Satisfied non-utun physical interface exists (Wi-Fi, Ethernet, Cellular)
    public var physicalInterfaceSatisfied: Bool
    /// Gateway exists on this path, i.e. default route present
    public var hasDefaultRoute: Bool

    public init(physicalInterfaceSatisfied: Bool, hasDefaultRoute: Bool) {
        self.physicalInterfaceSatisfied = physicalInterfaceSatisfied
        self.hasDefaultRoute = hasDefaultRoute
    }

    public var isUp: Bool { physicalInterfaceSatisfied && hasDefaultRoute }
}
