import Foundation
import Testing
@testable import GuardCore

// Tests use TEST-NET-2 (198.51.100.0/24, RFC 5737) addresses exclusively
private let allowedA = IPv4("198.51.100.10")!
private let allowedB = IPv4("198.51.100.11")!
private let outsideX = IPv4("198.51.100.9")!
private let outsideY = IPv4("198.51.100.200")!
private let allowlist: Set<IPv4> = [allowedA, allowedB]
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func obs(iface: String? = "utun4", ips: [IPv4]) -> Observation {
    Observation(clashRunning: true, routeInterface: iface, egressIPs: ips)
}

private func state(_ o: Observation, guard g: inout EgressGuard, path: NetworkPath? = up, at t: Date = t0) -> GuardDisplay {
    let v = g.observe(o, allowlist: allowlist, at: t)
    return GuardDisplay(verdict: v, observation: o, allowlist: allowlist, networkPath: path, violatedSince: g.violatedSince, checkedAt: t)
}

private func state(_ o: Observation, path: NetworkPath? = up) -> GuardDisplay {
    var g = EgressGuard()
    return state(o, guard: &g, path: path)
}

/// Egress IP in panel shares derivation with verdict: observed egress IP in round populates `GuardDisplay.egressIP`
@Suite struct EgressIPInDisplay {
    @Test func healthyRoundWritesTheObservedIP() {
        let s = state(obs(ips: [allowedA, allowedA]))
        #expect(s.verdict == .healthy)
        #expect(s.egressIP == "198.51.100.10")
    }

    /// Mismatch prefers displaying the IP outside allowlist, not accidentally matched IP
    @Test func mismatchPrefersTheIPOutsideTheAllowlist() {
        let s = state(obs(ips: [allowedA, outsideX, allowedB]))
        #expect(s.verdict == .egressMismatch)
        #expect(s.egressIP == "198.51.100.9")
    }

    /// On probe divergence: picks most frequent, ties broken by lowest numeric value; invariant to arrival order
    @Test func pickIsDeterministicRegardlessOfProbeOrder() {
        for ips in [[outsideY, outsideX, outsideY], [outsideX, outsideY, outsideY], [outsideY, outsideY, outsideX]] {
            #expect(obs(ips: ips).shownEgressIP(allowlist: allowlist) == outsideY)
        }
        for ips in [[outsideY, outsideX], [outsideX, outsideY]] {
            #expect(obs(ips: ips).shownEgressIP(allowlist: allowlist) == outsideX) // Numeric comparison .9 < .200
        }
        #expect(obs(ips: [allowedB, allowedA]).shownEgressIP(allowlist: allowlist) == allowedA)
    }

    /// Empty allowlist (config issue): verdict is unknown, but observed IP is still populated
    @Test func emptyAllowlistStillReportsTheObservedIP() {
        #expect(obs(ips: [outsideX]).shownEgressIP(allowlist: []) == outsideX)
    }

    /// Unobserved egress (offline, probes failed or timed out) evaluates to nil, displayed as "-"
    @Test(arguments: [up, down, nil] as [NetworkPath?])
    func noObservedEgressIsNil(_ path: NetworkPath?) {
        let s = state(obs(ips: []), path: path)
        #expect(s.verdict == .unknown)
        #expect(s.egressIP == nil)
    }

    /// Never carries over previous round's IP: if previous succeeded and current failed, writes nil
    @Test func neverCarriesOverThePreviousRoundsIP() {
        var g = EgressGuard()
        #expect(state(obs(ips: [allowedA]), guard: &g).egressIP == "198.51.100.10")
        #expect(state(obs(ips: []), guard: &g, at: t0.addingTimeInterval(5)).egressIP == nil)
    }

    /// Sticky violated continues reporting current round's observation (verdict sticky, IP unsticky)
    @Test func stickyViolatedReportsThisRoundsIP() {
        var g = EgressGuard()
        let first = state(obs(iface: "en0", ips: [outsideX]), guard: &g)
        #expect(first.verdict == .violated && first.egressIP == "198.51.100.9")
        let sticky = state(obs(ips: [allowedA, outsideY]), guard: &g, at: t0.addingTimeInterval(5))
        #expect(sticky.verdict == .violated && sticky.egressIP == "198.51.100.200")
        let blind = state(obs(ips: []), guard: &g, at: t0.addingTimeInterval(10))
        #expect(blind.verdict == .violated && blind.egressIP == nil)
    }
}
