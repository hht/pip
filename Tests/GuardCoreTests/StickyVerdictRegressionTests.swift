import Foundation
import Testing
@testable import GuardCore

/// Regression: red card cannot be dismissed (network disconnection -> recovery leaves red card active).
/// Verifies guard verdict evaluation:
/// - Only routes bypassing utun produce violated; disconnects, probe failures, egress mismatches never produce violated.
/// - violated is sticky, cleared only by a round of healthy; passing through unknown / egressMismatch does not clear or hang it.
/// App side (reaching healthy from any path dismisses card) covered by Notchkeeper tests.

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("198.51.100.66")!
private let allowlist: Set<IPv4> = [allowed]
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// Round: observation + network path snapshot
private struct Step {
    var observation: Observation
    var path: NetworkPath?
}

private let healthy = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [allowed]), path: up)
/// Proxy closed / TUN down: public route traverses physical interface
private let routeOff = Step(observation: Observation(clashRunning: true, routeInterface: "en0", egressIPs: [allowed]), path: up)
/// Disconnected, TUN active: route traverses utun, egress probes fail
private let offlineOnTunnel = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: []), path: down)
/// Disconnected, route unreadable
private let offlineNoRoute = Step(observation: Observation(clashRunning: true, routeInterface: nil, egressIPs: []), path: down)
/// Network satisfied but probes return no result
private let probesFail = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: []), path: up)
private let mismatch = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [leaked]), path: up)

/// Executes GuardCore per GuardMonitor round: verdict -> round result. 5-second interval between rounds
private func run(_ steps: [Step]) -> [GuardDisplay] {
    var g = EgressGuard()
    return steps.enumerated().map { i, s in
        let checkedAt = start.addingTimeInterval(Double(i) * 5)
        let v = g.observe(s.observation, allowlist: allowlist, at: checkedAt)
        return GuardDisplay(verdict: v, observation: s.observation, allowlist: allowlist, networkPath: s.path,
                            violatedSince: g.violatedSince, checkedAt: checkedAt)
    }
}

private func verdicts(_ d: [GuardDisplay]) -> [Verdict] { d.map(\.verdict) }

@Suite struct StickyVerdictRegression {
    /// 1. Outage then recovery: no violation throughout, ends healthy
    @Test func outageBetweenHealthyRoundsNeverViolates() {
        let d = run([healthy, offlineOnTunnel, healthy])
        #expect(verdicts(d) == [.healthy, .unknown, .healthy])
        #expect(d[1].unknownReason == .offline)
    }

    /// 2. Violation followed by unknown (outage / probe failure / route unreadable) persists until healthy, without hanging
    @Test func violatedStaysThroughUnknownUntilHealthy() {
        let d = run([routeOff, offlineOnTunnel, probesFail, offlineNoRoute, healthy])
        #expect(verdicts(d) == [.violated, .violated, .violated, .violated, .healthy])
        // Sticky violated carries no unknown reason (displays red card, not gray ring text)
        #expect(d.dropLast().allSatisfy { $0.unknownReason == nil })
        #expect(d.last?.unknownReason == nil)
    }

    /// 3. Violation followed by mismatch persists until healthy
    @Test func violatedStaysThroughMismatchUntilHealthy() {
        #expect(verdicts(run([routeOff, mismatch, mismatch, healthy])) == [.violated, .violated, .violated, .healthy])
    }

    /// 3b. Mismatch after release is amber, not violated
    @Test func afterReleaseMismatchIsAmberNotViolated() {
        #expect(verdicts(run([routeOff, healthy, mismatch, healthy])) == [.violated, .healthy, .egressMismatch, .healthy])
    }

    /// 4. Outage and recovery while route stays on utun: never violated
    @Test func outageAndRecoveryOnTunnelNeverViolates() {
        let d = run([healthy, offlineOnTunnel, offlineNoRoute, offlineOnTunnel, probesFail, healthy])
        #expect(!d.contains { $0.verdict == .violated })
        #expect(verdicts(d) == [.healthy, .unknown, .unknown, .unknown, .unknown, .healthy])
        #expect(d.map(\.unknownReason) == [nil, .offline, .offline, .offline, .probeFailed, nil])
    }

    /// 4b. Booting offline then recovering never violates
    @Test func startingOfflineThenRecoveringNeverViolates() {
        let d = run([offlineNoRoute, offlineOnTunnel, healthy])
        #expect(verdicts(d) == [.unknown, .unknown, .healthy])
        #expect(d.map(\.unknownReason) == [.offline, .offline, nil])
    }

    /// 5. Consecutive healthy rounds are idempotent
    @Test func healthyIsIdempotent() {
        let d = run([healthy, healthy, healthy])
        #expect(verdicts(d) == [.healthy, .healthy, .healthy])
        #expect(d.allSatisfy { $0.unknownReason == nil })
    }
}
