import Foundation

/// Answers: What settings exist in config.json and their default values. Saved at ~/Library/Application Support/Notchkeeper/config.json, read/written in App's `ConfigStore`.
/// Missing fields use defaults, unknown fields ignored; mismatched field types prevent decoding and `ConfigStore` preserves original file.
public struct Config: Codable, Equatable, Sendable {
    // General
    public var soundEnabled = true
    public var hoverExpand = true
    /// Pip eyes and body follow mouse, peeks over notch when mouse hovers (docs/mascot.md §5)
    public var mascotFollowsMouse = true
    // Egress Guard
    // No real egress built in: empty list leaves egress unknown, prompted in settings view
    public var allowlist: [String] = []
    public var autoAlert = true
    public var alertPersistent = true
    // Notifications
    public var cardAutoDismissSeconds = 6.0
    /// Additional schemes allowed for "Open URL" on cards besides https (`URLPolicy`)
    public var urlSchemes: [String] = []
    // Plugins: built-in use `PluginID`, external use directory name under `plugins/<id>/`. Default enabled with max 5 rows
    public var plugins: [String: PluginSettings] = [:]
    /// Section ordering in panel (egress guard fixed at top, not included here); unranked follow behind
    public var pluginOrder: [String] = []
    /// Displayed in collapsed state when all calm (docs/ui.md "Panel Layout"); empty string means no resident plugin
    public var residentPlugin = PluginID.exitGuard
    /// Shows Pip on left ear when collapsed; when disabled and idle, shows solid black notch (like boring.notch idle face option)
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

    /// Reordered plugins come first, unranked follow in original `available` order; ranked plugins no longer in `available` omitted
    public func ordered(_ available: [String]) -> [String] {
        let listed = pluginOrder.filter(available.contains)
        return listed + available.filter { !listed.contains($0) }
    }

    /// Move up (-1) or down (+1) by one slot; no-op at bounds. Stores full updated order
    public mutating func move(_ plugin: String, by offset: Int, in available: [String]) {
        var order = ordered(available)
        guard let i = order.firstIndex(of: plugin), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
        pluginOrder = order
    }
}

public struct PluginSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// Maximum rows shown for this section in panel, scrolls if exceeded
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
