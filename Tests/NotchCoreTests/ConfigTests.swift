import Foundation
import Testing
import NotchCore

/// Plugin configuration (docs/ui.md "Panel Layout"): default enabled, up to 5 rows per section, resident plugin is egress guard
@Suite struct PluginConfig {
    private func decode(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }

    @Test func defaults() {
        let c = Config()
        #expect(c.isEnabled("guard") && c.isEnabled("terminal"))
        #expect(c.maxRows("claude") == 5)
        #expect(c.residentPlugin == "guard" && c.showsEarMascot && c.pluginOrder.isEmpty)
    }

    /// Missing fields use defaults; row counts clamped to 1...5
    @Test func partialEntries() throws {
        let c = try decode(#"{"plugins":{"claude":{"enabled":false},"terminal":{"maxRows":9},"dl":{"maxRows":0}}}"#)
        #expect(!c.isEnabled("claude") && c.maxRows("claude") == 5)
        #expect(c.isEnabled("terminal") && c.maxRows("terminal") == 5)
        #expect(c.maxRows("dl") == 1)
    }

    /// Empty string means no resident plugin
    @Test func noResident() throws {
        #expect(try decode(#"{"residentPlugin":""}"#).resident == nil)
        #expect(Config().resident == "guard")
    }

    /// Section order: ranked sections first, unranked follow in default order; non-existent plugins omitted
    @Test func sectionOrder() throws {
        let c = try decode(#"{"pluginOrder":["terminal","gone","claude"]}"#)
        #expect(c.ordered(["claude", "dl", "terminal"]) == ["terminal", "claude", "dl"])
        #expect(Config().ordered(["claude", "dl"]) == ["claude", "dl"])
    }

    @Test func setters() {
        var c = Config()
        c.setEnabled(false, for: "dl")
        c.setMaxRows(2, for: "dl")
        #expect(!c.isEnabled("dl") && c.maxRows("dl") == 2)
        c.move("dl", by: -1, in: ["claude", "dl"])
        #expect(c.ordered(["claude", "dl"]) == ["dl", "claude"])
        c.move("dl", by: -1, in: ["claude", "dl"])
        #expect(c.ordered(["claude", "dl"]) == ["dl", "claude"])
    }

    @Test func roundTrips() throws {
        var c = Config()
        c.setEnabled(false, for: "guard")
        c.residentPlugin = ""
        c.showsEarMascot = false
        c.pluginOrder = ["dl"]
        #expect(try decode(String(decoding: JSONEncoder().encode(c), as: UTF8.self)) == c)
    }
}
