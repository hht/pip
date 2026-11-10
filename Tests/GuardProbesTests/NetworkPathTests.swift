import Testing
import GuardCore
@testable import GuardProbes

@Suite struct NetworkPathSnapshot {
    private func snap(_ satisfied: Bool, _ ifaces: [(String, Bool)], gateway: Bool = true) -> NetworkPath {
        NetworkPathProbe.snapshot(satisfied: satisfied, interfaces: ifaces.map { .init(name: $0.0, isPhysical: $0.1) },
                                  hasGateway: gateway)
    }

    @Test func wifiOrEthernetWithGatewayIsUp() {
        #expect(snap(true, [("en0", true)]) == NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true))
        #expect(snap(true, [("utun1024", false), ("en7", true)]).isUp)
    }

    /// Only utun (Clash's TUN) being satisfied does not count as having a physical network: TUN interface remains when disconnected
    @Test func onlyTunnelIsNotAPhysicalInterface() {
        #expect(!snap(true, [("utun1024", false)]).physicalInterfaceSatisfied)
        // Interfaces named utun never count, even if reported as physical by system
        #expect(!snap(true, [("utun3", true)]).physicalInterfaceSatisfied)
    }

    @Test func unsatisfiedPathIsDown() { #expect(!snap(false, [("en0", true)]).physicalInterfaceSatisfied) }
    @Test func noGatewayIsNoDefaultRoute() { #expect(!snap(true, [("en0", true)], gateway: false).hasDefaultRoute) }
}
