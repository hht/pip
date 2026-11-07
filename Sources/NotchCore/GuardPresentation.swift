import Foundation
import GuardCore
import MascotCore

/// 回答：守卫最近这一轮的结果，加上用户关掉的是哪一次违规，界面该画成什么、要不要红卡。
/// 纯函数，不知道文案和颜色（App 按 `status`、`tone` 去取），规则见 docs/egress-guard.md「怎么画」。
public struct GuardPresentation: Equatable, Sendable {
    /// 界面上说的那句话（docs/egress-guard.md「怎么画」）
    public enum Status: Equatable, Sendable {
        /// App 刚启动，第一轮还没查完
        case checking
        case healthy
        case mismatch
        case offline
        /// 探针没结果：不改造型，收起时右耳显示灰环
        case probeFailed
        case violated
    }

    /// 状态点：healthy 绿、mismatch 琥珀实心、unknown 灰色空心环、violated 红
    public enum Tone: Equatable, Sendable { case healthy, mismatch, unknown, violated }

    public let status: Status
    /// 要不要红卡（不代表撤卡：撤卡只看 healthy）。违规中、用户还没关掉这一次时才要
    public let wantsAlert: Bool

    /// - dismissedViolationSince: nil = 没关掉过；.some(x) = 用户关掉了 violatedSince 为 x 的那次
    public init(_ d: GuardDisplay, dismissedViolationSince: Date??) {
        wantsAlert = d.verdict == .violated && dismissedViolationSince != .some(d.violatedSince)
        switch d.verdict {
        case .healthy: status = .healthy
        case .egressMismatch: status = .mismatch
        case .violated: status = .violated
        case .unknown:
            switch d.unknownReason {
            case .offline: status = .offline
            case .probeFailed: status = .probeFailed
            case nil: status = .checking
            }
        }
    }

    public var tone: Tone {
        switch status {
        case .healthy: return .healthy
        case .mismatch: return .mismatch
        case .checking, .offline, .probeFailed: return .unknown
        case .violated: return .violated
        }
    }

    /// Pip 画成哪个守卫造型；没有守卫的事时是 idle（docs/mascot.md §2）
    public var look: Look {
        switch status {
        case .checking, .healthy, .probeFailed: return .idle
        case .mismatch: return .mismatch
        case .offline: return .offline
        case .violated: return .danger
        }
    }
}
