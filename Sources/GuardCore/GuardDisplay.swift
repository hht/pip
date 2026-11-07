import Foundation

/// 回答：出口守卫最近一轮查到了什么，App 该显示什么。
/// 由一轮的判定和观测算出来，不知道观测怎么拿（GuardProbes 的 `GuardMonitor`），也不知道画成什么样（NotchCore 的 `GuardPresentation`）。
/// IP 只出现在 `egressIP`（界面完整显示），日志不记它（CLAUDE.md「日志不记 IP」）。
public struct GuardDisplay: Equatable, Sendable {
    public var verdict: Verdict
    /// 这一轮查完的时刻；`nil` 是 App 这次启动后还没查完第一轮（`checking`）
    public var checkedAt: Date?
    /// 只有 verdict 是 unknown 且查过一轮时才有（见 `UnknownReason`）
    public var unknownReason: UnknownReason?
    /// 只有 verdict 是 violated 时才有：这次违规开始的那一轮（见 `EgressGuard.violatedSince`）。App 用它记用户关掉的是哪一次
    public var violatedSince: Date?
    /// 这一轮观测到的出口 IP（见 `Observation.shownEgressIP`）。没拿到就是 `nil`，绝不沿用上一轮；粘住的 violated 期间也是这一轮的
    public var egressIP: String?

    /// App 刚启动、第一轮还没查完
    public static let checking = GuardDisplay(verdict: .unknown)

    public init(verdict: Verdict, checkedAt: Date? = nil, unknownReason: UnknownReason? = nil, violatedSince: Date? = nil, egressIP: String? = nil) {
        self.verdict = verdict
        self.checkedAt = checkedAt
        self.unknownReason = unknownReason
        self.violatedSince = violatedSince
        self.egressIP = egressIP
    }

    /// 一轮的结果。`networkPath` 是这一轮的网络快照（`nil` 是没拿到），只用来决定 `unknownReason`；
    /// `violatedSince` 传 `EgressGuard.violatedSince`，verdict 不是 violated 时忽略
    public init(verdict: Verdict, observation o: Observation, allowlist: Set<IPv4>, networkPath: NetworkPath?,
                violatedSince: Date?, checkedAt: Date) {
        self.init(verdict: verdict, checkedAt: checkedAt,
                  unknownReason: UnknownReason.decide(verdict: verdict, path: networkPath),
                  violatedSince: verdict == .violated ? violatedSince : nil,
                  egressIP: o.shownEgressIP(allowlist: allowlist)?.description)
    }
}

/// 回答：App 的配置、插件、命令行工具这些文件放在哪个目录。只求路径，不碰文件。
public enum GuardPaths {
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Notchkeeper", isDirectory: true)
    public static let configFile = directory.appendingPathComponent("config.json")
}
