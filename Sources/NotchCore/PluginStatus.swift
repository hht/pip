import AgentCore
import MascotCore

/// 回答：一个插件此刻多急、收起时 Pip 和右耳画什么；几个插件里谁上位（照灵动岛 relevanceScore：最急的那个显示在收起态）。
/// 不知道插件开没开（App 只把开着的传进来）、也不知道面板里列什么（`PanelRow`）。
/// @see https://developer.apple.com/documentation/activitykit/activitycontent/relevancescore
public struct PluginStatus: Equatable, Sendable {
    public enum Urgency: Int, Comparable, Sendable {
        case calm, active, attention, critical

        public static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
    }

    public let plugin: String
    public let urgency: Urgency
    public let look: Look
    public let indicator: EarIndicator

    /// 严重只有出口守卫能报（CLAUDE.md 硬规则「插件」）：别的插件报了降成要你看
    init(plugin: String, urgency: Urgency, look: Look, indicator: EarIndicator) {
        self.plugin = plugin
        self.urgency = urgency == .critical && plugin != PluginID.exitGuard ? .attention : urgency
        self.look = look
        self.indicator = indicator
    }

    /// 违规严重；不一致、断网要你看；健康、第一轮还没查完、探针没结果平静（探针没结果只在右耳画灰环）
    public init(guard p: GuardPresentation) {
        let urgency: Urgency = switch p.status {
        case .checking, .healthy, .probeFailed: .calm
        case .mismatch, .offline: .attention
        case .violated: .critical
        }
        self.init(plugin: PluginID.exitGuard, urgency: urgency, look: p.look, indicator: .for(p.look, probeFailed: p.status == .probeFailed))
    }

    /// 等你回答、批准要你看；工作中、干了很久、刚做完进行中；没有要画的平静
    public init(agent: AgentActivity?) {
        let urgency: Urgency = switch agent {
        case nil: .calm
        case .finished?, .working?, .longTurn?: .active
        case .question?, .approval?: .attention
        }
        let look = agent.map(Look.init) ?? .idle
        self.init(plugin: PluginID.claudeCode, urgency: urgency, look: look, indicator: .for(look, probeFailed: false))
    }

    /// 外部插件：紧急程度是它开着的活动里最急的那个（`ActivityBoard`），造型跟着紧急程度走
    public init(external plugin: String, urgency: Urgency) {
        let look: Look = switch urgency {
        case .calm: .idle
        case .active: .working
        case .attention, .critical: .question
        }
        self.init(plugin: plugin, urgency: urgency, look: look, indicator: .for(look, probeFailed: false))
    }

    /// 最急的上位，一样急时排在前面的上位（App 按守卫、再按面板段的顺序传）；都平静时是常驻插件，不常驻或它关着就没有
    public static func lead(_ statuses: [PluginStatus], resident: String?) -> PluginStatus? {
        let top = statuses.reduce(nil as PluginStatus?) { best, s in s.urgency > (best?.urgency ?? .calm) ? s : best }
        return top ?? statuses.first { $0.plugin == resident }
    }
}

extension Look {
    public init(_ activity: AgentActivity) {
        switch activity {
        case .finished: self = .finished
        case .working: self = .working
        case .longTurn: self = .longTurn
        case .question: self = .question
        case .approval: self = .approval
        }
    }
}
