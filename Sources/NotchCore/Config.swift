import Foundation

/// 回答：config.json 里有哪些设置、缺了取什么默认值。存在 ~/Library/Application Support/Notchkeeper/config.json，读写在 App 的 `ConfigStore`。
/// 缺失的字段用默认值，未知字段忽略；字段类型不对就整份解不开，由 `ConfigStore` 保留原文件。
public struct Config: Codable, Equatable, Sendable {
    // 通用
    public var soundEnabled = true
    public var hoverExpand = true
    /// Pip 的眼睛和身体跟着鼠标走、鼠标到刘海上时探头（docs/mascot.md §5）
    public var mascotFollowsMouse = true
    // 出口守卫
    // 不内置任何真实出口：空列表时守卫判不了出口（unknown），设置页会提示
    public var allowlist: [String] = []
    public var autoAlert = true
    public var alertPersistent = true
    // 通知
    public var cardAutoDismissSeconds = 6.0
    /// 卡片上「打开 URL」除 https 外还放行的 scheme（`URLPolicy`）
    public var urlSchemes: [String] = []
    // 插件：内置的按 `PluginID`，外部的按 `plugins/<id>/` 的目录名。没写的插件开着、每段最多露 5 行
    public var plugins: [String: PluginSettings] = [:]
    /// 面板里各段的顺序（出口守卫固定在顶上，不在这里）；没排过的跟在后面
    public var pluginOrder: [String] = []
    /// 都平静时收起态显示谁（docs/ui.md「面板布局」）；空串是不常驻
    public var residentPlugin = PluginID.exitGuard
    /// 收起时左耳画 Pip；关掉后什么都没有要显示时就是一块纯黑的刘海（照 boring.notch 的空闲脸选项）
    public var showsEarMascot = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? def
        }
        soundEnabled = try v(.soundEnabled, d.soundEnabled)
        hoverExpand = try v(.hoverExpand, d.hoverExpand)
        mascotFollowsMouse = try v(.mascotFollowsMouse, d.mascotFollowsMouse)
        allowlist = try v(.allowlist, d.allowlist)
        autoAlert = try v(.autoAlert, d.autoAlert)
        alertPersistent = try v(.alertPersistent, d.alertPersistent)
        cardAutoDismissSeconds = min(10, max(2, try v(.cardAutoDismissSeconds, d.cardAutoDismissSeconds)))
        urlSchemes = try v(.urlSchemes, d.urlSchemes)
        plugins = try v(.plugins, d.plugins)
        pluginOrder = try v(.pluginOrder, d.pluginOrder)
        residentPlugin = try v(.residentPlugin, d.residentPlugin)
        showsEarMascot = try v(.showsEarMascot, d.showsEarMascot)
    }

    public func isEnabled(_ plugin: String) -> Bool { plugins[plugin]?.enabled ?? true }
    public func maxRows(_ plugin: String) -> Int { plugins[plugin]?.maxRows ?? PluginSettings().maxRows }
    public var resident: String? { residentPlugin.isEmpty ? nil : residentPlugin }

    public mutating func setEnabled(_ on: Bool, for plugin: String) { plugins[plugin, default: PluginSettings()].enabled = on }
    public mutating func setMaxRows(_ n: Int, for plugin: String) { plugins[plugin, default: PluginSettings()].maxRows = PluginSettings.clamp(n) }

    /// 排过的在前、没排过的按 `available` 原来的顺序跟在后面；排过但已经不在 `available` 里的不出现
    public func ordered(_ available: [String]) -> [String] {
        let listed = pluginOrder.filter(available.contains)
        return listed + available.filter { !listed.contains($0) }
    }

    /// 上移（-1）或下移（+1）一格；到头了不动。存下整份当前顺序
    public mutating func move(_ plugin: String, by offset: Int, in available: [String]) {
        var order = ordered(available)
        guard let i = order.firstIndex(of: plugin), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
        pluginOrder = order
    }
}

public struct PluginSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// 面板里这一段最多露几行，多的在段里滚
    public var maxRows = 5

    public static let rowRange = 1...5
    public static func clamp(_ n: Int) -> Int { min(rowRange.upperBound, max(rowRange.lowerBound, n)) }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxRows = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .maxRows) ?? 5)
    }
}
