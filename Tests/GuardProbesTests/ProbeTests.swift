import Foundation
import Testing
import GuardCore
@testable import GuardProbes

// Real output of `route -n get 1.1.1.1` (Clash Verge TUN enabled)
private let routeOutputTUN = """
   route to: 1.1.1.1
destination: 1.0.0.0
       mask: 255.0.0.0
    gateway: 198.18.0.1
  interface: utun1024
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
"""

@Suite struct RouteParsing {
    @Test func checksClaudeRouteDirectly() { #expect(RouteProbe.destinations.first?.hasPrefix("160.79.10") == true) }
    /// LAN exemption: only queries public addresses, routes connected directly to LAN are never judged anomalous
    @Test func destinationsAreAllPublic() {
        for d in RouteProbe.destinations {
            let o = d.split(separator: ".").compactMap { Int($0) }
            #expect(o.count == 4)
            #expect(!(o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254) || o[0] == 127), "\(d) is a LAN address")
        }
    }
    @Test func readsInterfaceLine() { #expect(RouteProbe.parseInterface(routeOutputTUN) == "utun1024") }
    @Test func noInterfaceLineIsNil() { #expect(RouteProbe.parseInterface("route: writing to routing socket: not in table") == nil) }

    @Test func anyNonTunnelWins() { #expect(RouteProbe.combine(["utun1024", "en0"]) == "en0") }
    @Test func allTunnelIsTunnel() { #expect(RouteProbe.combine(["utun1024", "utun1024"]) == "utun1024") }
    @Test func partialLookupUsesKnown() { #expect(RouteProbe.combine([nil, "utun1024"]) == "utun1024") }
    @Test func noLookupIsUnknown() { #expect(RouteProbe.combine([nil, nil]) == nil) }
}

@Suite struct ClashDetection {
    @Test func matchesCoreByExecutableName() {
        #expect(ClashProbe.isRunning(executablePaths: [
            "/Applications/Clash Verge.app/Contents/MacOS/clash-verge",
            "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo",
        ]))
    }

    /// Running GUI or privileged service alone without the core does not count as running
    @Test func guiOrServiceAloneIsNotCore() {
        #expect(!ClashProbe.isRunning(executablePaths: [
            "/Applications/Clash Verge.app/Contents/MacOS/clash-verge",
            "/Library/PrivilegedHelperTools/io.github.clash-verge-rev.clash-verge-rev.service.bundle/Contents/MacOS/clash-verge-service",
        ]))
    }

    @Test func substringIsNotMatch() { #expect(!ClashProbe.isRunning(executablePaths: ["/tmp/not-verge-mihomo-really"])) }
}

private enum Canned: Error { case timeout, other }

private func probe(_ responses: [String: Result<(String, Int), Canned>]) -> EgressProbe {
    let urls = responses.keys.sorted().compactMap(URL.init(string:))
    return EgressProbe(endpoints: urls) { url in
        switch responses[url.absoluteString]! {
        case let .success((body, status)): return (Data(body.utf8), status)
        case .failure(.timeout): throw URLError(.timedOut)
        case .failure(.other): throw URLError(.cannotConnectToHost)
        }
    }
}

@Suite struct EgressProbing {
    @Test func collectsEveryValidAnswer() async {
        let sample = await probe([
            "https://a.example": .success(("198.51.100.8\n", 200)),
            "https://b.example": .success(("1.2.3.4", 200)),
        ]).current()
        #expect(Set(sample.ips) == [IPv4("198.51.100.8")!, IPv4("1.2.3.4")!])
        #expect(sample.failures.isEmpty)
    }

    @Test func dropsAndCountsFailuresByKind() async {
        let sample = await probe([
            "https://a.example": .success(("198.51.100.8", 500)),
            "https://b.example": .success(("<html>blocked</html>", 200)),
            "https://c.example": .failure(.other),
            "https://d.example": .success(("010.1.1.1", 200)),
            "https://e.example": .failure(.timeout),
        ]).current()
        #expect(sample.ips.isEmpty)
        #expect(sample.failures == [.badStatus: 1, .unparseable: 2, .transport: 1, .timeout: 1])
    }

    @Test func liveEndpointsAvoidAnthropic() {
        #expect(EgressProbe.live.endpoints.allSatisfy { !($0.host ?? "").contains("anthropic") && !($0.host ?? "").contains("claude") })
        #expect(EgressProbe.live.endpoints.count >= 2)
    }
}

/// Hardware smoke test: skipped by default. `NOTCHKEEPER_LIVE_PROBES=1 swift test --filter LiveProbes` prints real 3-way results,
/// only reading local routing table and process list, and querying 3 IP echo services without modifying any settings. Does not print IP (CLAUDE.md: no IPs in logs).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOTCHKEEPER_LIVE_PROBES"] == "1"))
struct LiveProbes {
    @Test func printsRealObservation() async {
        let sample = await EgressProbe.live.current()
        let route = await RouteProbe.current()
        print("live route=\(route ?? "nil") clash=\(ClashProbe.current().map(String.init) ?? "nil") ips=\(sample.ips.count) distinct=\(Set(sample.ips).count) failures=\(sample.failures)")
    }
}
