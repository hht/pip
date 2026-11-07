import Foundation
import GuardCore
import Network
import os

/// 回答：本机此刻的网络路径快照（有没有不经过 TUN 的物理网络）。守卫每轮取一次，测试换成桩。
public protocol NetworkPathSource: Sendable {
    /// 还没拿到快照时返回 `nil`（不是「断网」）
    func current() async -> NetworkPath?
}

/// 把 Network.framework 的路径换成两个布尔值。纯函数，不碰网络。
public enum NetworkPathProbe {
    struct Interface: Sendable {
        var name: String
        var isPhysical: Bool
    }

    /// 名字以 utun 开头的一律不算物理网卡：断网时 Clash 的 TUN 网卡仍在。
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

/// 常驻的 `NWPathMonitor`，只读：不发包、不改任何网络设置。排除 `.other`（utun 属于这类）和回环，
/// 所以路径只在物理网卡上求值，Clash 的 TUN 不会让断网看起来像有网。
/// 系统在路径变化时回调，这里只记下最新快照；`current()` 直接返回它，刚启动还没回调时最多等 2 秒。
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
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil } // 一轮截止时被取消
        }
        return latest.withLock { $0 }
    }
}
