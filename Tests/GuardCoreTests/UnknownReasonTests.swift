import Foundation
import Testing
@testable import GuardCore

private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let noInterface = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: true)
private let noRoute = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: false)
private let nothing = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let unknownRound = Observation(clashRunning: true, routeInterface: nil, egressIPs: [])

@Suite struct UnknownReasonDecision {
    @Test(arguments: [noInterface, noRoute, nothing])
    func offlineWhenNoPhysicalInterfaceOrNoDefaultRoute(_ p: NetworkPath) {
        #expect(!p.isUp)
        #expect(UnknownReason.decide(verdict: .unknown, path: p) == .offline)
    }

    @Test func probeFailedWhenNetworkIsUp() {
        #expect(up.isUp)
        #expect(UnknownReason.decide(verdict: .unknown, path: up) == .probeFailed)
    }

    /// Missing snapshot cannot assert offline; treated as probeFailed
    @Test func noSnapshotIsProbeFailed() { #expect(UnknownReason.decide(verdict: .unknown, path: nil) == .probeFailed) }

    /// Priority: offline takes precedence as probes necessarily fail during disconnect
    @Test func offlineBeatsProbeFailed() {
        var g = EgressGuard()
        #expect(g.observe(Observation(clashRunning: nil, routeInterface: nil, egressIPs: []), allowlist: []) == .unknown)
        #expect(UnknownReason.decide(verdict: .unknown, path: nothing) == .offline)
    }

    @Test(arguments: [Verdict.healthy, .egressMismatch, .violated])
    func onlyUnknownCarriesAReason(_ v: Verdict) {
        for p in [up, noInterface, noRoute, nothing, nil] as [NetworkPath?] {
            #expect(UnknownReason.decide(verdict: v, path: p) == nil)
        }
    }
}

@Suite struct UnknownReasonInDisplay {
    private func display(_ v: Verdict, path: NetworkPath?) -> GuardDisplay {
        GuardDisplay(verdict: v, observation: unknownRound, allowlist: [], networkPath: path, violatedSince: nil, checkedAt: now)
    }

    @Test func unknownCarriesTheReason() {
        #expect(display(.unknown, path: nothing).unknownReason == .offline)
        #expect(display(.unknown, path: up).unknownReason == .probeFailed)
    }

    @Test(arguments: [Verdict.healthy, .egressMismatch, .violated])
    func otherVerdictsCarryNoReason(_ v: Verdict) {
        #expect(display(v, path: nothing).unknownReason == nil)
    }
}
