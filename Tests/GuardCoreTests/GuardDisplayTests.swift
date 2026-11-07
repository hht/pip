import Foundation
import Testing
@testable import GuardCore

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("198.51.100.66")!
private let allowlist: Set<IPv4> = [allowed]
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)

private func display(clash: Bool? = true, iface: String? = "utun1024", ips: [IPv4] = [allowed]) -> GuardDisplay {
    let o = Observation(clashRunning: clash, routeInterface: iface, egressIPs: ips)
    var g = EgressGuard()
    let v = g.observe(o, allowlist: allowlist, at: t0)
    return GuardDisplay(verdict: v, observation: o, allowlist: allowlist, networkPath: up, violatedSince: g.violatedSince, checkedAt: t0)
}

@Suite struct GuardDisplayFromRound {
    @Test func healthyRound() {
        #expect(display() == GuardDisplay(verdict: .healthy, checkedAt: t0, egressIP: allowed.description))
    }

    /// violatedSince 只跟着 violated 走；unknown 原因只跟着 unknown 走
    @Test func fieldsFollowTheVerdict() {
        #expect(display(iface: "en0") == GuardDisplay(verdict: .violated, checkedAt: t0, violatedSince: t0, egressIP: allowed.description))
        #expect(display(ips: []) == GuardDisplay(verdict: .unknown, checkedAt: t0, unknownReason: .probeFailed))
        let o = Observation(clashRunning: true, routeInterface: "utun1024", egressIPs: [allowed])
        #expect(GuardDisplay(verdict: .healthy, observation: o, allowlist: allowlist, networkPath: up, violatedSince: t0, checkedAt: t0).violatedSince == nil)
    }

    /// 还没查完第一轮：unknown，没有原因、没有时间
    @Test func checkingHasNothingYet() {
        #expect(GuardDisplay.checking == GuardDisplay(verdict: .unknown))
    }
}

@Suite struct ObservationSignals {
    private func o(iface: String? = "utun1024", ips: [IPv4] = [allowed]) -> Observation {
        Observation(clashRunning: true, routeInterface: iface, egressIPs: ips)
    }

    @Test func routeOnTunnel() {
        #expect(o().routeOnTunnel == true)
        #expect(o(iface: "en0").routeOnTunnel == false)
        #expect(o(iface: nil).routeOnTunnel == nil)
    }

    /// 没拿到 IP、或允许列表为空，都是「不知道」，不是「对上了」
    @Test func egressMatchIsUnknownWithoutEvidence() {
        #expect(o(ips: [allowed, leaked]).egressMatches(allowlist) == false)
        #expect(o(ips: []).egressMatches(allowlist) == nil)
        #expect(o(ips: [leaked]).egressMatches([]) == nil)
    }
}
