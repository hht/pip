import Foundation

/// Answers: based on a round of observations, is egress healthy, egressMismatch, unknown, or violated.
/// Agnostic of observation sources (Clash process, routing table, HTTP probes live outside), and agnostic of downstream usage.
///
/// Rules (detailed in docs/egress-guard.md): guard monitors only, never blocks; blocking belongs to firewall (docs/firewall.md).
/// 1. Public route not traversing utun (GuardProbes.RouteProbe, not default route) -> immediately violated (red card).
/// 2. Probes observe IP not in allowed list -> egressMismatch: solid amber. Echo services may be routed by Clash to different nodes,
///    acting as indirect evidence only. Empty allowed list is a configuration issue, treating IP as unknown.
/// 3. Clash running, route traverses utun, and all IPs in allowed list -> healthy; otherwise (Clash absent, route unreadable,
///    probes timed out) -> unknown. If Clash is absent but route and IP are normal, no traffic leaked.
/// 4. violated is sticky: cleared only by a full round of healthy. Probe failures during disconnection never dismiss red card.
///    Stickiness applies within current App run only: App restart starts at unknown, and if route still bypasses utun, next round evaluates violated.

/// A single round of observations. `nil` represents missing results, i.e. "unknown", not "normal".
public struct Observation: Sendable {
    public var clashRunning: Bool?
    public var routeInterface: String?
    /// Egress IPs obtained by probes; failed probes are omitted.
    public var egressIPs: [IPv4]

    public init(clashRunning: Bool?, routeInterface: String?, egressIPs: [IPv4]) {
        self.clashRunning = clashRunning
        self.routeInterface = routeInterface
        self.egressIPs = egressIPs
    }

    /// Whether route traverses utun; `nil` means route unreadable.
    public var routeOnTunnel: Bool? { routeInterface.map { $0.hasPrefix("utun") } }

    /// Whether obtained IPs are all in allowed list; missing IPs or empty allowed list evaluate to `nil` (unknown).
    public func egressMatches(_ allowlist: Set<IPv4>) -> Bool? {
        guard !allowlist.isEmpty, !egressIPs.isEmpty else { return nil }
        return egressIPs.allSatisfy(allowlist.contains)
    }

    /// Egress IP reported to App for display this round (`GuardDisplay.egressIP`); `nil` if not obtained, never carrying over previous round.
    /// If disallowed IPs exist, picks among those; picks most frequent on divergence, lowest numeric on tie, invariant to probe arrival order.
    /// Display only, non-participating in verdict.
    public func shownEgressIP(allowlist: Set<IPv4>) -> IPv4? {
        let outside = egressIPs.filter { !allowlist.contains($0) }
        let counts = Dictionary((outside.isEmpty ? egressIPs : outside).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.min { a, b in
            a.value != b.value ? a.value > b.value : a.key.octets.lexicographicallyPrecedes(b.key.octets)
        }?.key
    }
}

public enum Verdict: String, Codable, Sendable, Equatable {
    case healthy
    /// Egress IP not in allowed list (Rule 2)
    case egressMismatch
    case unknown
    /// Route not traversing utun (Rule 1)
    case violated
}

public struct EgressGuard: Sendable {
    public private(set) var verdict: Verdict = .unknown
    /// Round when violation began: set upon entering violated, invariant while sticky, cleared on healthy. Present only when violated.
    /// App uses it to distinguish the same violation incident from a new one.
    public private(set) var violatedSince: Date?

    public init() {}

    /// `now` used only to record `violatedSince`, non-participating in verdict evaluation.
    public mutating func observe(_ o: Observation, allowlist: Set<IPv4>, at now: Date = Date()) -> Verdict {
        let route = o.routeOnTunnel, egress = o.egressMatches(allowlist)
        let next: Verdict
        if route == false {
            next = .violated
        } else if egress == false {
            next = .egressMismatch
        } else if egress == true, route == true, o.clashRunning == true {
            next = .healthy
        } else {
            next = .unknown
        }

        if verdict == .violated, next != .healthy { return verdict } // Rule 4
        violatedSince = next == .violated ? now : nil // Sticky violation returns above; violated here is always a fresh incident
        verdict = next
        return verdict
    }
}
