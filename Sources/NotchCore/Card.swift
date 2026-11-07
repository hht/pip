import Foundation

/// 回答：一张卡上写什么——谁发的、标题、右侧短值、结果、底部内容块、点了去哪。
/// 纯值：不知道颜色、声音、Pip 造型和版式（App 按 `outcome` 去取），也不知道它什么时候放（`CardQueue`）。
/// 一眼能看完：构造时按条数和长度截断（docs/ui.md「卡片」）。内容块照 Adaptive Cards 起名（TextBlock、FactSet），进度和勾叉列表是扩展。
/// @see https://github.com/microsoft/AdaptiveCards/tree/main/schemas/src/elements
public struct Card: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case exitGuard
        case claudeCode
        /// 外部插件：卡上标明是谁发的（CLAUDE.md 硬规则「外部插件可信但受限」）
        case plugin(id: String, name: String, symbol: String)
    }

    /// 发生了什么：App 据此定流星颜色、Pip 造型、提示音
    public enum Outcome: Equatable, Sendable {
        case done, failed, question, approval, info, recovered
        /// 要你看，但不是等你回答或批准
        case attention
        /// 出口违规：只有出口守卫能用
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

    /// 底部内容块，一张卡至多一个
    public enum Block: Equatable, Sendable {
        /// TextBlock：正文，Markdown 子集，一行一项，留前 3 行（外部文字在边界按换行切好）
        case text([String])
        /// TextBlock + monospace：日志尾巴，留后 3 行
        case log([String])
        /// FactSet：键值，至多 4 对
        case facts([Fact])
        /// 勾叉列表，至多 3 项
        case checklist([Check])
        /// 进度 0…1
        case progress(Double, label: String?)
    }

    /// 点卡片或按钮去哪：只有这三种（CLAUDE.md 硬规则「插件」）。打开 URL 放不放行看 `URLPolicy`
    public enum Action: Equatable, Sendable {
        case open(URL)
        case activate(bundleID: String)
        case terminal(TerminalRef)
    }

    /// 卡片右下的按钮，至多两个；点了也算关掉这张卡
    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: Action
        public init(title: String, action: Action) { self.title = title; self.action = action }
    }

    public static let maxText = 200
    /// 右侧短值和插件名：长了会把标题挤没
    public static let maxValue = 24
    public static let maxLines = 3
    public static let maxFacts = 4
    public static let maxButtons = 2

    /// 活动的卡每次更新都新造，id 沿用第一张：App 认出是同一张，原地换内容（`CardQueue.update`）
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
        // 红色和绿色只属于出口守卫（CLAUDE.md 硬规则「插件」）
        switch outcome {
        case .violation where source != .exitGuard: self.outcome = .attention
        case .recovered where source != .exitGuard: self.outcome = .done
        default: self.outcome = outcome
        }
        self.block = block.flatMap(Self.capped)
        self.action = action
        self.buttons = buttons.prefix(Self.maxButtons).map { Button(title: Self.capped($0.title, to: Self.maxValue), action: $0.action) }
    }

    /// 外部插件的 id，内置插件的卡是 nil：外部的卡红卡挂着时排着，不盖它
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

/// 终端里的哪个会话：点卡片跳回它的 Ghostty 窗口
public struct TerminalRef: Equatable, Sendable {
    /// 防 pid 复用：往 pid 的 tty 写标记之前，先确认它还是那个进程
    public enum Identity: Equatable, Sendable {
        /// Claude Code 会话：进程启动时刻对得上
        case started(Date)
        /// 外部插件说的 shell（没有启动时刻）：pid 的控制终端还是这个 tty
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
