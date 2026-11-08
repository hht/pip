import Foundation
import GuardCore
import Network
import os

/// Answers: snapshot of the local network path at this moment (whether there is a physical network not going through TUN).
/// Guard takes this once per round; replaced with stubs in tests.
public protocol NetworkPathSource: Sendable {
    /// Returns `nil` when a snapshot has not been retrieved yet (not "disconnected").
    func current() async -> NetworkPath?
}

/// Converts Network.framework path into two booleans. Pure function, no network access.
public enum NetworkPathProbe {
    struct Interface: Sendable {
        var name: String
        var isPhysical: Bool
    }

    /// Interfaces starting with utun never count as physical: Clash's TUN interface still exists when disconnected.
    static func snapshot(satisfied: Bool, interfaces: [Interface], hasGateway: Bool) -> NetworkPath {
        let physical = interfaces.contains { $0.isPhysical && !$0.name.hasPrefix("utun") }
        return NetworkPath(physicalInterfaceSatisfied: satisfied && physical, hasDefaultRoute: hasGateway)
    }

    static func snapshot(of p: NWPath) -> NetworkPath {
        let physicalTypes: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular]
        return snapshot(satisfied: p.status == .satisfied,
                        interfaces: p.availableInterfaces.map { Interface(name: $0.name, isPhysical: physicalTypes.contains($0.type)) },
                        hasGateway: !p.gateways.isEmpty)
    }
}

/// Resident `NWPathMonitor`, read-only: sends no packets, modifies no network settings. Excludes `.other` (utun belongs here) and loopback,
/// so path evaluates only on physical interfaces; Clash TUN won't make a disconnected state appear connected.
/// System callbacks fire on path changes; this only records the latest snapshot; `current()` returns it directly, waiting up to 2 seconds if just launched before first callback.
/// @see https://developer.apple.com/documentation/network/nwpathmonitor
public final class LiveNetworkPath: NetworkPathSource, @unchecked Sendable {
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
    private let latest = OSAllocatedUnfairLock<NetworkPath?>(initialState: nil)

    public init() {
        let latest = self.latest
        monitor.pathUpdateHandler = { path in
            let snapshot = NetworkPathProbe.snapshot(of: path)
            latest.withLock { $0 = snapshot }
        }
        monitor.start(queue: DispatchQueue(label: "com.notchkeeper.guard.network-path", qos: .utility))
    }

    deinit { monitor.cancel() }

    public func current() async -> NetworkPath? {
        for _ in 0..<40 {
            if let p = latest.withLock({ $0 }) { return p }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil } // Cancelled when round deadline expires
        }
        return latest.withLock { $0 }
    }
}
