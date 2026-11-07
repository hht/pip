import Foundation
import Testing
@testable import NotchCore

private let long = String(repeating: "长", count: 500)
private func card(_ outcome: Card.Outcome = .done, source: Card.Source = .plugin(id: "terminal", name: "终端", symbol: "terminal"),
                  title: String = "npm 跑完了", block: Card.Block? = nil) -> Card {
    Card(source: source, title: title, subtitle: "~/x", value: "2 分 13 秒", outcome: outcome, block: block)
}

/// 卡片一眼能看完：每种内容块都限条数，字符串限长（docs/ui.md「卡片」）。块的名字照 Adaptive Cards（TextBlock、FactSet），进度和勾叉列表是扩展
@Suite struct CardLimits {
    @Test func stringsAreCapped() {
        let c = Card(source: .plugin(id: "x", name: long, symbol: long), title: long, subtitle: long, value: long, outcome: .done,
                     block: .text([long]))
        #expect(c.title.count == Card.maxText && c.subtitle?.count == Card.maxText)
        #expect(c.title.hasSuffix("…"))
        // 右侧短值太长会把标题挤没
        #expect(c.value?.count == Card.maxValue)
        guard case .plugin(_, let name, let symbol) = c.source, case .text(let t) = c.block else { Issue.record("来源或块变了"); return }
        #expect(name.count == Card.maxValue && t[0].count == Card.maxText)
        // 图标名截断了就不是图标名了：长度由 `Manifest` 登记时拦
        #expect(symbol == long)
    }

    @Test func textKeepsFirstThreeLines() {
        #expect(card(block: .text(["一", "二", "三", "四", "五"])).block == .text(["一", "二", "三"]))
    }

    /// 日志看的是最后几行（tail）
    @Test func logKeepsLastThreeLines() {
        let c = card(block: .log(["1", "2", "3", "4", "5"]))
        #expect(c.block == .log(["3", "4", "5"]))
    }

    @Test func factsAndChecklistAreCapped() {
        let facts = (1...6).map { Card.Fact(title: "k\($0)", value: "v\($0)") }
        #expect(card(block: .facts(facts)).block == .facts(Array(facts.prefix(4))))
        let checks = (1...5).map { Card.Check(text: "步\($0)", state: .ok) }
        #expect(card(block: .checklist(checks)).block == .checklist(Array(checks.prefix(3))))
    }

    @Test(arguments: [(-1.0, 0.0), (0.42, 0.42), (3.0, 1.0), (Double.nan, 0.0)])
    func progressIsClamped(_ raw: Double, _ expected: Double) {
        #expect(card(block: .progress(raw, label: nil)).block == .progress(expected, label: nil))
    }

    /// 空的块不画：没有内容的块等于没有块
    @Test func emptyBlocksDisappear() {
        for b: Card.Block in [.text([]), .log([]), .facts([]), .checklist([])] {
            #expect(card(block: b).block == nil)
        }
    }
}

/// 红卡和 danger 只属于出口守卫：外部插件冒充不了（CLAUDE.md 硬规则「外部插件可信但受限」）
@Suite struct CardTrust {
    @Test func onlyGuardMayRaiseViolation() {
        #expect(card(.violation, source: .exitGuard).outcome == .violation)
        #expect(card(.violation, source: .claudeCode).outcome == .attention)
        #expect(card(.violation).outcome == .attention)
    }

    /// 绿色只给出口正常：外部插件发不出「出口已恢复」
    @Test func onlyGuardMayRecover() {
        #expect(card(.recovered, source: .exitGuard).outcome == .recovered)
        #expect(card(.recovered).outcome == .done)
        #expect(card(.recovered, source: .claudeCode).outcome == .done)
    }
}

/// 按钮至多两个，标题和短值一样短（ntfy 的 actions、Adaptive Cards 的 ActionSet）
@Suite struct CardButtons {
    @Test func atMostTwoShortButtons() {
        let long = String(repeating: "按", count: 100)
        let buttons = (1...4).map { Card.Button(title: "\($0)\(long)", action: .activate(bundleID: "com.example.app")) }
        let c = Card(source: .claudeCode, title: "t", outcome: .done, buttons: buttons)
        #expect(c.buttons.count == 2)
        #expect(c.buttons.allSatisfy { $0.title.count == Card.maxValue })
    }
}
