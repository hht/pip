@testable import AgentCore
import Foundation
import GuardCore
import MascotCore
import Testing
@testable import NotchCore

private func guardStatus(_ verdict: Verdict, unknown: UnknownReason? = nil) -> PluginStatus {
    PluginStatus(guard: GuardPresentation(display(verdict, unknown: unknown), dismissedViolationSince: nil))
}

/// 每个插件报一个带紧急程度的状态（照灵动岛 relevanceScore）：收起时 Pip 和右耳显示最急的那个
@Suite struct PluginStatusUrgencies {
    @Test func guardUrgencies() {
        #expect(guardStatus(.healthy).urgency == .calm)
        #expect(guardStatus(.unknown, unknown: .probeFailed).urgency == .calm)
        #expect(PluginStatus(guard: GuardPresentation(.checking, dismissedViolationSince: nil)).urgency == .calm)
        #expect(guardStatus(.egressMismatch).urgency == .attention)
        #expect(guardStatus(.unknown, unknown: .offline).urgency == .attention)
        #expect(guardStatus(.violated).urgency == .critical)
    }

    /// 探针没结果不改造型，只在右耳画灰环
    @Test func probeFailedShowsRing() {
        let s = guardStatus(.unknown, unknown: .probeFailed)
        #expect(s.look == .idle && s.indicator == .ring)
    }

    @Test(arguments: [(AgentActivity?.none, PluginStatus.Urgency.calm, Look.idle), (.finished, .active, .finished), (.working, .active, .working),
                      (.longTurn, .active, .longTurn), (.question, .attention, .question), (.approval, .attention, .approval)])
    func agentUrgencies(_ activity: AgentActivity?, _ urgency: PluginStatus.Urgency, _ look: Look) {
        let s = PluginStatus(agent: activity)
        #expect(s.plugin == PluginID.claudeCode && s.urgency == urgency && s.look == look)
    }

    /// 外部插件的造型由紧急程度定：进行中是 working，要你看是 question
    @Test func externalLooks() {
        #expect(PluginStatus(external: "dl", urgency: .active).look == .working)
        #expect(PluginStatus(external: "dl", urgency: .attention).indicator == .dot(.question))
        #expect(PluginStatus(external: "dl", urgency: .calm).indicator == EarIndicator.none)
    }

    /// 严重只有守卫能报（CLAUDE.md 硬规则「插件」）
    @Test func onlyGuardIsCritical() {
        #expect(PluginStatus(external: "dl", urgency: .critical).urgency == .attention)
    }
}

/// 谁上位：最急的；一样急按顺序（守卫在前，其余按面板段的顺序）；都平静时是常驻插件，不常驻就没有
@Suite struct LeadingStatus {
    private let calmGuard = guardStatus(.healthy)
    private let working = PluginStatus(agent: .working)

    @Test func mostUrgentLeads() {
        let q = PluginStatus(agent: .question)
        #expect(PluginStatus.lead([calmGuard, q, PluginStatus(external: "dl", urgency: .active)], resident: PluginID.exitGuard) == q)
    }

    @Test func tieGoesToEarlier() {
        let offline = guardStatus(.unknown, unknown: .offline)
        let q = PluginStatus(agent: .question)
        #expect(PluginStatus.lead([offline, q], resident: nil) == offline)
        #expect(PluginStatus.lead([q, offline], resident: nil) == q)
    }

    @Test func calmShowsResident() {
        let calmAgent = PluginStatus(agent: nil)
        #expect(PluginStatus.lead([calmGuard, calmAgent], resident: PluginID.exitGuard) == calmGuard)
        #expect(PluginStatus.lead([calmGuard, calmAgent], resident: PluginID.claudeCode) == calmAgent)
        #expect(PluginStatus.lead([calmGuard, calmAgent], resident: nil) == nil)
    }

    /// 常驻插件关掉了（不在列表里）：和不常驻一样
    @Test func disabledResidentIsNone() {
        #expect(PluginStatus.lead([PluginStatus(agent: nil)], resident: PluginID.exitGuard) == nil)
    }

    @Test func noPlugins() {
        #expect(PluginStatus.lead([], resident: PluginID.exitGuard) == nil)
    }

    @Test func activeBeatsCalmResident() {
        #expect(PluginStatus.lead([calmGuard, working], resident: PluginID.exitGuard) == working)
    }
}

/// 面板的行模板（docs/ui.md「面板布局」）：Claude 会话也走它
@Suite struct SessionRows {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ state: AgentState) -> Session {
        Session(pid: 42, processStart: since, sessionId: "s", cwd: NSHomeDirectory() + "/Projects/x", state: state, stateSince: since)
    }

    @Test func workingSession() {
        let row = PanelRow(session(.working))
        #expect(row.icon == .claude)
        #expect(row.title == "~/Projects/x" && row.titleIsPath)
        #expect(row.indicator == .working && row.trailing == .since(since) && !row.dimmed)
        #expect(row.action == .terminal(TerminalRef(pid: 42, identity: .started(since), cwd: NSHomeDirectory() + "/Projects/x")))
    }

    @Test(arguments: [(AgentState.needsYou(.question), PanelRow.Indicator.question), (.needsYou(.approval), .approval)])
    func needsYou(_ state: AgentState, _ indicator: PanelRow.Indicator) {
        #expect(PanelRow(session(state)).indicator == indicator)
    }

    /// 已停止：不画指示，图标和路径变暗
    @Test func stoppedIsDimmed() {
        let row = PanelRow(session(.stopped))
        #expect(row.indicator == PanelRow.Indicator.none && row.dimmed)
    }
}
