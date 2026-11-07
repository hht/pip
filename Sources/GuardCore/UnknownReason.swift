/// 回答：一轮判成 unknown 时，是因为本机根本没网（灰），还是网通着但探针没拿到结果。
/// 只给 unknown 用：healthy、egressMismatch、violated 永远没有原因。UI 的颜色不看它（所有 unknown 同一个灰色空心环），
/// 只用它选文字，见 docs/egress-guard.md「怎么画」一节。
public enum UnknownReason: String, Codable, Sendable, Equatable {
    /// 没有满足的非 utun 物理网卡，或没有默认路由
    case offline
    /// 网络通着（或没拿到网络快照），但路由 / Clash / 出口探针没给出能判定的结果
    case probeFailed

    /// 断网优先：断网时探针必然也失败，报 offline 才说得清。没拿到快照不能断言断网，算 probeFailed。
    /// 不需要看这一轮的观测：unknown 本身已经说明探针没给出结果，网络快照决定是哪一种。
    public static func decide(verdict: Verdict, path: NetworkPath?) -> UnknownReason? {
        guard verdict == .unknown else { return nil }
        if let path, !path.isUp { return .offline }
        return .probeFailed
    }
}

/// 回答：本机此刻有没有一条不经过 TUN 的物理网络。来自 Network.framework 的路径快照（GuardProbes），只读。
/// 只存两个布尔值，不存网卡名、地址（CLAUDE.md「日志不记 IP」）。
public struct NetworkPath: Sendable, Equatable {
    /// 有状态为 satisfied 的非 utun 物理网卡（Wi-Fi、有线、蜂窝）
    public var physicalInterfaceSatisfied: Bool
    /// 这条路径上有网关，即有默认路由
    public var hasDefaultRoute: Bool

    public init(physicalInterfaceSatisfied: Bool, hasDefaultRoute: Bool) {
        self.physicalInterfaceSatisfied = physicalInterfaceSatisfied
        self.hasDefaultRoute = hasDefaultRoute
    }

    public var isUp: Bool { physicalInterfaceSatisfied && hasDefaultRoute }
}
