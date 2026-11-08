import Foundation

/// Answers: What appears on a card — sender, title, right short value, outcome, bottom block, click action.
/// Pure value: agnostic of colors, sounds, Pip look, and layout (App fetches them via `outcome`), and display timing (`CardQueue`).
/// Glanceable: truncated by item count and length at initialization (docs/ui.md "Cards"). Content blocks follow Adaptive Cards naming (TextBlock, FactSet), progress and checklist are extensions.
/// @see https://github.com/microsoft/AdaptiveCards/tree/main/schemas/src/elements
public struct Card: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case exitGuard
        case claudeCode
        /// External plugin: card indicates sender (CLAUDE.md hard rule "External plugins are trusted but restricted")
        case plugin(id: String, name: String, symbol: String)
    }

    /// What happened: App determines streak color, Pip look, cue sound accordingly
    public enum Outcome: Equatable, Sendable {
        case done, failed, question, approval, info, recovered
        /// Needs attention, but not waiting for user response or approval
        case attention
        /// Egress violation: only egress guard may use this
        case violation
    }

    public struct Fact: Equatable, Sendable {
        public var title: String
        public var value: String
        public init(title: String, value: String) { self.title = title; self.value = value }
    }

    public struct Check: Equatable, Sendable {
        public enum State: Equatable, Sendable { case ok, failed, pending }
        public var text: String
        public var state: State
        public init(text: String, state: State) { self.text = text; self.state = state }
    }

    /// Bottom content block, at most one per card
    public enum Block: Equatable, Sendable {
        /// TextBlock: body text, Markdown subset, one item per line, keeps first 3 lines (external text split on newlines)
        case text([String])
        /// TextBlock + monospace: log tail, keeps last 3 lines
        case log([String])
        /// FactSet: key-value pairs, at most 4 pairs
        case facts([Fact])
        /// Checklist, at most 3 items
        case checklist([Check])
        /// Progress 0…1
        case progress(Double, label: String?)
    }

    /// Where clicking card or button navigates: only these three (CLAUDE.md hard rule "Plugins"). URL opening checked by `URLPolicy`
    public enum Action: Equatable, Sendable {
        case open(URL)
        case activate(bundleID: String)
        case terminal(TerminalRef)
    }

    /// Buttons at bottom-right of card, at most two; clicking also dismisses card
    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: Action
        public init(title: String, action: Action) { self.title = title; self.action = action }
    }

    public static let maxText = 200
    /// Short value and plugin name on right: prevents crowding out title
    public static let maxValue = 24
    public static let maxLines = 3
    public static let maxFacts = 4
    public static let maxButtons = 2

    /// Activity card recreated on each update, reusing id from first card: App updates in-place (`CardQueue.update`)
    public let id: UUID
    public let source: Source
    public let title: String
    public private(set) var subtitle: String?
    public let value: String?
    public let outcome: Outcome
    public let block: Block?
    public let action: Action?
    public let buttons: [Button]

    public init(id: UUID = UUID(), source: Source, title: String, subtitle: String? = nil, value: String? = nil, outcome: Outcome,
                block: Block? = nil, action: Action? = nil, buttons: [Button] = []) {
        self.id = id
        if case .plugin(let id, let name, let symbol) = source {
            self.source = .plugin(id: id, name: Self.capped(name, to: Self.maxValue), symbol: symbol)
        } else {
            self.source = source
        }
        self.title = Self.capped(title)
        self.subtitle = subtitle.map { Self.capped($0) }
        self.value = value.map { Self.capped($0, to: Self.maxValue) }
        // Red and green only belong to egress guard (CLAUDE.md hard rule "Plugins")
        switch outcome {
        case .violation where source != .exitGuard: self.outcome = .attention
        case .recovered where source != .exitGuard: self.outcome = .done
        default: self.outcome = outcome
        }
        self.block = block.flatMap(Self.capped)
        self.action = action
        self.buttons = buttons.prefix(Self.maxButtons).map { Button(title: Self.capped($0.title, to: Self.maxValue), action: $0.action) }
    }

    /// External plugin ID, nil for built-in plugin cards: external cards queue while red card is active
    public var externalPluginID: String? {
        if case .plugin(let id, _, _) = source { return id }
        return nil
    }

    static func capped(_ s: String, to limit: Int = maxText) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    private static func capped(_ block: Block) -> Block? {
        switch block {
        case .text(let lines):
            return lines.isEmpty ? nil : .text(lines.prefix(maxLines).map { capped($0) })
        case .log(let lines):
            return lines.isEmpty ? nil : .log(lines.suffix(maxLines).map { capped($0) })
        case .facts(let facts):
            return facts.isEmpty ? nil : .facts(facts.prefix(maxFacts).map { Fact(title: capped($0.title), value: capped($0.value)) })
        case .checklist(let checks):
            return checks.isEmpty ? nil : .checklist(checks.prefix(maxLines).map { Check(text: capped($0.text), state: $0.state) })
        case .progress(let p, let label):
            return .progress(p.isNaN ? 0 : min(max(p, 0), 1), label: label.map { capped($0) })
        }
    }
}

/// Session in terminal: clicking card jumps to its Ghostty window
public struct TerminalRef: Equatable, Sendable {
    /// Prevent PID reuse: verify process before writing marker to tty
    public enum Identity: Equatable, Sendable {
        /// Claude Code session: matched by process start time
        case started(Date)
        /// Shell from external plugin (no start time): matched by controlling terminal tty
        case tty(String)
    }

    public var pid: Int32
    public var identity: Identity
    public var cwd: String
    public init(pid: Int32, identity: Identity, cwd: String) {
        self.pid = pid
        self.identity = identity
        self.cwd = cwd
    }
}
