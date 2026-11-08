import AgentCore
import Foundation

/// Answers: What a row in a plugin's panel section displays — icon, title, optional subtitle, status indicator, right-side elapsed time or short value, click action (docs/ui.md "Panel Layout").
/// Content determined by plugin (Claude sessions, external plugin activities), layout determined by App; agnostic of colors and copy. Only includes paths, status, and times, not conversational text
public struct PanelRow: Identifiable, Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        /// Claude brand mark
        case claude
        /// SF Symbol name
        case symbol(String)
    }

    /// Indicators only, no text; copy reserved for tooltips and VoiceOver
    public enum Indicator: Equatable, Sendable {
        case none, working, question, approval, attention
        case progress(Double)
    }

    public enum Trailing: Equatable, Sendable {
        /// Time elapsed since status change
        case since(Date)
        case value(String)
    }

    public var id: String
    public var icon: Icon
    public var title: String
    /// Title is a file path: truncated from start if too long, keeping trailing segments
    public var titleIsPath = false
    public var subtitle: String?
    public var indicator: Indicator
    public var trailing: Trailing
    /// Stopped sessions: icon and title dimmed, timestamp remains bright (maintaining contrast)
    public var dimmed = false
    public var action: Card.Action?

    public init(id: String, icon: Icon, title: String, titleIsPath: Bool = false, subtitle: String? = nil, indicator: Indicator,
                trailing: Trailing, dimmed: Bool = false, action: Card.Action? = nil) {
        self.id = id
        self.icon = icon
        self.title = title
        self.titleIsPath = titleIsPath
        self.subtitle = subtitle
        self.indicator = indicator
        self.trailing = trailing
        self.dimmed = dimmed
        self.action = action
    }

    /// Claude session: path + status indicator + elapsed time since status change; click jumps to terminal. Does not show session name (which may be inferred from conversation)
    public init(_ session: Session) {
        let indicator: Indicator = switch session.state {
        case .working: .working
        case .needsYou(.question): .question
        case .needsYou(.approval): .approval
        case .stopped: .none
        }
        self.init(id: "claude:\(session.pid)", icon: .claude, title: (session.cwd as NSString).abbreviatingWithTildeInPath, titleIsPath: true,
                  indicator: indicator, trailing: .since(session.stateSince), dimmed: session.state == .stopped,
                  action: .terminal(TerminalRef(session)))
    }
}

extension TerminalRef {
    public init(_ session: Session) { self.init(pid: session.pid, identity: .started(session.processStart), cwd: session.cwd) }
}

/// A plugin's section in the panel (docs/ui.md "Panel Layout")
public struct PanelSection: Identifiable, Equatable, Sendable {
    public var plugin: String
    public var rows: [PanelRow]
    /// Maximum rows displayed, excess scrolls within section
    public var maxRows: Int
    public var id: String { plugin }

    public init(plugin: String, rows: [PanelRow], maxRows: Int) {
        self.plugin = plugin
        self.rows = rows
        self.maxRows = maxRows
    }
}
