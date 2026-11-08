import Testing
@testable import GuardCore

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("1.2.3.4")!
private let allowlist: Set<IPv4> = [allowed, IPv4("198.51.100.7")!]

private func obs(clash: Bool? = true, iface: String? = "utun4", ips: [IPv4] = [allowed]) -> Observation {
    Observation(clashRunning: clash, routeInterface: iface, egressIPs: ips)
}

private func run(_ seq: [Observation]) -> [Verdict] {
    var g = EgressGuard()
    return seq.map { g.observe($0, allowlist: allowlist) }
}

@Suite struct IPv4Parsing {
    @Test(arguments: ["198.51.100.8", "0.0.0.0", "255.255.255.255"])
    func accepts(_ s: String) { #expect(IPv4(s)?.description == s) }

    @Test(arguments: ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "1.2.3.4 ", "+1.2.3.4", "١.2.3.4", "1234.1.1.1", "010.1.1.1", "1.2.3.00"])
    func rejects(_ s: String) { #expect(IPv4(s) == nil) }
}

@Suite struct Verdicts {
    @Test func allGoodIsHealthy() { #expect(run([obs()]) == [.healthy]) }

    /// Clash down while route and IP normal: no traffic leaked, evaluates as unknown
    @Test func clashDownAloneIsUnknown() {
        #expect(run([obs(clash: false)]) == [.unknown])
    }

    @Test func clashDownWithRouteOffTunnelIsViolated() {
        #expect(run([obs(clash: false, iface: "en0")]) == [.violated])
    }

    @Test func routeOffTunnelIsImmediate() {
        #expect(run([obs(iface: "en0")]) == [.violated])
    }

    /// Disallowed egress IP warns only, never evaluates as violated
    @Test func badEgressOnlyWarnsNeverViolates() {
        #expect(run([obs(ips: [leaked]), obs(ips: [leaked]), obs(ips: [leaked])])
            == [.egressMismatch, .egressMismatch, .egressMismatch])
    }

    @Test func anyBadProbeIsMismatch() {
        #expect(run([obs(ips: [allowed, leaked])]) == [.egressMismatch])
    }

    @Test func mismatchWinsOverMissingSignals() {
        #expect(run([obs(clash: nil, ips: [leaked])]) == [.egressMismatch])
    }

    @Test func goodRoundClearsMismatch() {
        #expect(run([obs(ips: [leaked]), obs()]) == [.egressMismatch, .healthy])
    }

    @Test(arguments: [
        obs(clash: nil), obs(iface: nil), obs(ips: []),
    ])
    func missingSignalIsUnknown(_ o: Observation) { #expect(run([o]) == [.unknown]) }

    /// violated is cleared only by a full healthy round: disconnects, timeouts, mismatches do not clear it
    @Test func violationIsStickyUntilHealthy() {
        #expect(run([obs(iface: "en0"), obs(ips: []), obs(clash: nil), obs(ips: [leaked])])
            == [.violated, .violated, .violated, .violated])
    }

    @Test func fullHealthyRoundClearsViolation() {
        #expect(run([obs(iface: "en0"), obs()]) == [.violated, .healthy])
    }

    @Test func routeRuleWinsOverMismatch() {
        #expect(run([obs(iface: "en0", ips: [leaked])]) == [.violated])
    }

    /// Empty allowlist is a configuration issue: IPs treated as unknown
    @Test func emptyAllowlistIsUnknown() {
        var g = EgressGuard()
        #expect(g.observe(obs(ips: [leaked]), allowlist: []) == .unknown)
    }
}
