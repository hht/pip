import AgentCore
import MascotCore

/// Answers: How urgent a plugin is right now, what Pip and right ear show when collapsed, and which plugin takes precedence (following Dynamic Island relevanceScore: most urgent shows in collapsed state).
/// Agnostic of whether plugin is enabled (App passes only enabled ones) and what panel lists (`PanelRow`).
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

    /// Critical can only be reported by egress guard (CLAUDE.md hard rule "Plugins"): others downgraded to attention
    init(plugin: String, urgency: Urgency, look: Look, indicator: EarIndicator) {
        self.plugin = plugin
        self.urgency = urgency == .critical && plugin != PluginID.exitGuard ? .attention : urgency
        self.look = look
        self.indicator = indicator
    }

    /// Violated is critical; mismatch and offline need attention; healthy, initial checking, and probe failed are calm (probe failed shows gray ring on right ear)
    public init(guard p: GuardPresentation) {
        let urgency: Urgency = switch p.status {
        case .checking, .healthy, .probeFailed: .calm
        case .mismatch, .offline: .attention
        case .violated: .critical
        }
        self.init(plugin: PluginID.exitGuard, urgency: urgency, look: p.look, indicator: .for(p.look, probeFailed: p.status == .probeFailed))
    }

    /// Question/approval need attention; working, long turn, finished are active; idle is calm
    public init(agent: AgentActivity?) {
        let urgency: Urgency = switch agent {
        case nil: .calm
        case .finished?, .working?, .longTurn?: .active
        case .question?, .approval?: .attention
        }
        let look = agent.map(Look.init) ?? .idle
        self.init(plugin: PluginID.claudeCode, urgency: urgency, look: look, indicator: .for(look, probeFailed: false))
    }

    /// External plugins: urgency matches highest urgency among active activities (`ActivityBoard`), look follows urgency
    public init(external plugin: String, urgency: Urgency) {
        let look: Look = switch urgency {
        case .calm: .idle
        case .active: .working
        case .attention, .critical: .question
        }
        self.init(plugin: plugin, urgency: urgency, look: look, indicator: .for(look, probeFailed: false))
    }

    /// Most urgent takes precedence; ties broken by order passed by App (guard first, then panel section order); when all calm, falls back to resident plugin
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
