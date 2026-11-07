import Foundation

/// 回答：根据一轮观测，出口现在是 healthy、egressMismatch、unknown 还是 violated。
/// 不知道观测从哪来（Clash 进程、路由表、HTTP 探针都在外层），也不知道判定结果拿去做什么。
///
/// 规则（完整说明见 docs/egress-guard.md）：守卫只监测，不拦截；拦截归防火墙（docs/firewall.md）。
/// 1. 去往公网的路由不走 utun（见 GuardProbes.RouteProbe，不是默认路由）→ 立即 violated（红卡）。
/// 2. 探针拿到不在允许列表的 IP → egressMismatch：只亮琥珀色。回显服务可能被 Clash 分到和
///    别的 App 不同的节点，这个信号只是间接证据。允许列表为空是配置问题，IP 一律算未知。
/// 3. Clash 在、路由走 utun、IP 都在允许列表，三者都成立才 healthy；其余（Clash 不在、读不到路由、
///    探针全超时）→ unknown。Clash 不在但路由和 IP 正常时流量并没有漏出去。
/// 4. violated 是粘性的：只有一轮完整的 healthy 才能解除。断网时探针全失败，不能因此撤掉红卡。
///    粘性只在 App 这次运行之内：App 重启后从 unknown 开始，路由还不走 utun 的话下一轮照样 violated。

/// 一轮观测。`nil` 表示这一路没拿到结果，即「未知」，不是「正常」。
public struct Observation: Sendable {
    public var clashRunning: Bool?
    public var routeInterface: String?
    /// 各探针拿到的出口 IP；失败的探针不放进来。
    public var egressIPs: [IPv4]

    public init(clashRunning: Bool?, routeInterface: String?, egressIPs: [IPv4]) {
        self.clashRunning = clashRunning
        self.routeInterface = routeInterface
        self.egressIPs = egressIPs
    }

    /// 路由走没走 utun；`nil` 是没读到路由。
    public var routeOnTunnel: Bool? { routeInterface.map { $0.hasPrefix("utun") } }

    /// 拿到的 IP 是否全在允许列表；没拿到 IP、或允许列表为空（配置问题）都是 `nil`（未知）。
    public func egressMatches(_ allowlist: Set<IPv4>) -> Bool? {
        guard !allowlist.isEmpty, !egressIPs.isEmpty else { return nil }
        return egressIPs.allSatisfy(allowlist.contains)
    }

    /// 这一轮报给 App 显示的出口 IP（`GuardDisplay.egressIP`）；没拿到 IP 是 `nil`，绝不拿上一轮的补。
    /// 有不在允许列表的就只从这些里挑（出口不符时显示的是不符的那个）；回显服务说法不一时取出现次数最多的，
    /// 一样多取数值最小的，和探针返回的先后无关。只用于显示，不参与判定。
    public func shownEgressIP(allowlist: Set<IPv4>) -> IPv4? {
        let outside = egressIPs.filter { !allowlist.contains($0) }
        let counts = Dictionary((outside.isEmpty ? egressIPs : outside).map { ($0, 1) }, uniquingKeysWith: +)
        return counts.min { a, b in
            a.value != b.value ? a.value > b.value : a.key.octets.lexicographicallyPrecedes(b.key.octets)
        }?.key
    }
}

public enum Verdict: String, Codable, Sendable, Equatable {
    case healthy
    /// 出口 IP 不在允许列表（规则 2）
    case egressMismatch
    case unknown
    /// 路由不走 utun（规则 1）
    case violated
}

public struct EgressGuard: Sendable {
    public private(set) var verdict: Verdict = .unknown
    /// 这次违规从哪一轮开始：进入 violated 的那一轮设上，粘住期间不变，healthy 解除时清空。只有 violated 时才有。
    /// App 用它区分「同一次违规」和「新的一次」（用户关掉红卡记的是它）。
    public private(set) var violatedSince: Date?

    public init() {}

    /// `now` 只用来记 `violatedSince`，不影响判定。
    public mutating func observe(_ o: Observation, allowlist: Set<IPv4>, at now: Date = Date()) -> Verdict {
        let route = o.routeOnTunnel, egress = o.egressMatches(allowlist)
        let next: Verdict
        if route == false {
            next = .violated
        } else if egress == false {
            next = .egressMismatch
        } else if egress == true, route == true, o.clashRunning == true {
            next = .healthy
        } else {
            next = .unknown
        }

        if verdict == .violated, next != .healthy { return verdict } // 规则 4
        violatedSince = next == .violated ? now : nil // 粘住时上面已经返回，这里的 violated 一定是新的一次
        verdict = next
        return verdict
    }
}
