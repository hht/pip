@testable import AgentCore
import Foundation
import GuardCore
import MascotCore
import Testing
@testable import NotchCore

private func guardStatus(_ verdict: Verdict, unknown: UnknownReason? = nil) -> PluginStatus {
    PluginStatus(guard: GuardPresentation(display(verdict, unknown: unknown), dismissedViolationSince: nil))
}

/// Each plugin reports status with urgency (following Dynamic Island relevanceScore): collapsed state shows Pip and right ear for most urgent
@Suite struct PluginStatusUrgencies {
    @Test func guardUrgencies() {
        #expect(guardStatus(.healthy).urgency == .calm)
        #expect(guardStatus(.unknown, unknown: .probeFailed).urgency == .calm)
        #expect(PluginStatus(guard: GuardPresentation(.checking, dismissedViolationSince: nil)).urgency == .calm)
        #expect(guardStatus(.egressMismatch).urgency == .attention)
        #expect(guardStatus(.unknown, unknown: .offline).urgency == .attention)
        #expect(guardStatus(.violated).urgency == .critical)
    }

    /// Probe failed does not change look, shows gray ring on right ear only
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

    /// External plugin look determined by urgency: active is working, attention is question
    @Test func externalLooks() {
        #expect(PluginStatus(external: "dl", urgency: .active).look == .working)
        #expect(PluginStatus(external: "dl", urgency: .attention).indicator == .dot(.question))
        #expect(PluginStatus(external: "dl", urgency: .calm).indicator == EarIndicator.none)
    }

    /// Critical can only be reported by guard (CLAUDE.md hard rule "Plugins")
    @Test func onlyGuardIsCritical() {
        #expect(PluginStatus(external: "dl", urgency: .critical).urgency == .attention)
    }
}

/// Precedence: most urgent leads; ties broken by order (guard first, remaining by section order); falls back to resident when all calm, none if no resident
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

    /// Resident plugin disabled (not in list): behaves like no resident
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

/// Panel row template (docs/ui.md "Panel Layout"): Claude sessions also use it
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

    /// Stopped: no indicator, icon and path dimmed
    @Test func stoppedIsDimmed() {
        let row = PanelRow(session(.stopped))
        #expect(row.indicator == PanelRow.Indicator.none && row.dimmed)
    }
}
