import Foundation
import GuardCore

/// 回答：守卫又查完一轮之后，红卡该挂上、撤掉还是不动；撤掉时弹不弹恢复卡。
/// 「用户关掉的是哪一次违规」「这次违规弹过红卡没有」只在这里记（docs/egress-guard.md、docs/ui.md「卡片」）。
/// 纯状态机：红卡什么时候在台面上归 `CardQueue`，卡长什么样归 App。
public struct ViolationAlert: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// 新的一次违规：红卡插到最前，响 Basso
        case raise
        /// 查到 healthy：撤掉红卡；recovered 时弹恢复卡
        case clear(recovered: Bool)
    }

    private var display: GuardDisplay
    /// nil = 没关掉过；.some(x) = 用户关掉了 violatedSince 为 x 的那次。只在内存：App 重启后红卡再出现一次，宁可多提醒
    private var dismissedViolationSince: Date??
    /// 红卡挂着
    private var shown = false
    /// 这次违规弹过红卡：回到 healthy 才弹恢复卡。中间断网、探针没结果、用户关掉红卡都算同一次
    private var alerted = false
    /// 设置里出口守卫插件开着：关着时照常判定，但不挂红卡、不弹恢复卡
    private var enabled = true

    public init(_ d: GuardDisplay) { display = d }

    public var presentation: GuardPresentation { GuardPresentation(display, dismissedViolationSince: dismissedViolationSince) }

    /// 守卫每查完一轮调用一次。autoAlert：设置「出口异常时弹出红卡」
    public mutating func read(_ d: GuardDisplay, autoAlert: Bool) -> Action {
        display = d
        if d.verdict == .healthy { dismissedViolationSince = nil }
        guard enabled else { return .none }
        if presentation.status == .healthy {
            defer { shown = false; alerted = false }
            return shown || alerted ? .clear(recovered: alerted) : .none
        }
        guard presentation.wantsAlert, autoAlert else { return .none }
        alerted = true
        guard !shown else { return .none }
        shown = true
        return .raise
    }

    /// 开关出口守卫插件。关掉：撤红卡、不弹恢复卡（关的是提醒，不是判定）；打开：按最近一轮的结果再判一次
    public mutating func setEnabled(_ on: Bool, autoAlert: Bool) -> Action {
        guard on != enabled else { return .none }
        enabled = on
        if on { return read(display, autoAlert: autoAlert) }
        defer { shown = false; alerted = false }
        return shown ? .clear(recovered: false) : .none
    }

    /// 红卡收起了、违规没恢复（用户点了 ×，或不常驻的红卡到时）。只在违规还挂着时记下，演示红卡关掉不算
    public mutating func dismiss() {
        shown = false
        guard presentation.status == .violated else { return }
        dismissedViolationSince = .some(display.violatedSince)
    }

    #if DEBUG
    /// scripts/demo.sh alert：挂一张红卡，下次读到 healthy 撤掉，不弹恢复卡。只有 DEBUG 构建听 demo.sh
    public mutating func demo() -> Action {
        shown = true
        return .raise
    }
    #endif
}
