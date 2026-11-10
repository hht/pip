import Foundation
import Testing
@testable import GuardCore

/// `violatedSince`: stable identifier for a violation from inception until cleared by healthy, used by App to record "which incident user dismissed".

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("198.51.100.66")!
private let allowlist: Set<IPv4> = [allowed]
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private let healthy = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [allowed])
private let routeOff = Observation(clashRunning: true, routeInterface: "en0", egressIPs: [allowed])
private let probesFail = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [])
private let mismatch = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [leaked])

@Suite struct ViolatedSince {
    private func run(_ steps: [(Observation, TimeInterval)], start g: EgressGuard = EgressGuard()) -> [(Verdict, Date?)] {
        var g = g
        return steps.map { o, t in
            let v = g.observe(o, allowlist: allowlist, at: t0.addingTimeInterval(t))
            return (v, g.violatedSince)
        }
    }

    @Test func setOnFirstViolatedRoundAndUnchangedWhileSticky() {
        let r = run([(healthy, 0), (routeOff, 5), (probesFail, 10), (mismatch, 15), (routeOff, 20)])
        #expect(r.map(\.0) == [.healthy, .violated, .violated, .violated, .violated])
        #expect(r[0].1 == nil)
        #expect(r.dropFirst().allSatisfy { $0.1 == t0.addingTimeInterval(5) })
    }

    @Test func clearedOnReleaseAndANewViolationGetsANewValue() {
        let r = run([(routeOff, 0), (healthy, 5), (mismatch, 10), (probesFail, 15), (routeOff, 20)])
        #expect(r.map(\.0) == [.violated, .healthy, .egressMismatch, .unknown, .violated])
        #expect(r.map(\.1) == [t0, nil, nil, nil, t0.addingTimeInterval(20)])
    }

    @Test func freshGuardStartsUnknown() {
        let g = EgressGuard()
        #expect(g.verdict == .unknown && g.violatedSince == nil)
    }
}
