import Foundation
import Testing
@testable import NotchCore

private let long = String(repeating: "a", count: 500)
private func card(_ outcome: Card.Outcome = .done, source: Card.Source = .plugin(id: "terminal", name: "Terminal", symbol: "terminal"),
                  title: String = "npm finished", block: Card.Block? = nil) -> Card {
    Card(source: source, title: title, subtitle: "~/x", value: "2m 13s", outcome: outcome, block: block)
}

/// Glanceable cards: each block type has item limits, string lengths capped (docs/ui.md "Cards"). Block names follow Adaptive Cards (TextBlock, FactSet), progress and checklist are extensions
@Suite struct CardLimits {
    @Test func stringsAreCapped() {
        let c = Card(source: .plugin(id: "x", name: long, symbol: long), title: long, subtitle: long, value: long, outcome: .done,
                     block: .text([long]))
        #expect(c.title.count == Card.maxText && c.subtitle?.count == Card.maxText)
        #expect(c.title.hasSuffix("…"))
        // Short value too long would crowd out title
        #expect(c.value?.count == Card.maxValue)
        guard case .plugin(_, let name, let symbol) = c.source, case .text(let t) = c.block else { Issue.record("Source or block changed"); return }
        #expect(name.count == Card.maxValue && t[0].count == Card.maxText)
        // Icon name truncation breaks SF Symbol: length capped at Manifest registration
        #expect(symbol == long)
    }

    @Test func textKeepsFirstThreeLines() {
        #expect(card(block: .text(["One", "Two", "Three", "Four", "Five"])).block == .text(["One", "Two", "Three"]))
    }

    /// Logs inspect tail lines
    @Test func logKeepsLastThreeLines() {
        let c = card(block: .log(["1", "2", "3", "4", "5"]))
        #expect(c.block == .log(["3", "4", "5"]))
    }

    @Test func factsAndChecklistAreCapped() {
        let facts = (1...6).map { Card.Fact(title: "k\($0)", value: "v\($0)") }
        #expect(card(block: .facts(facts)).block == .facts(Array(facts.prefix(4))))
        let checks = (1...5).map { Card.Check(text: "step\($0)", state: .ok) }
        #expect(card(block: .checklist(checks)).block == .checklist(Array(checks.prefix(3))))
    }

    @Test(arguments: [(-1.0, 0.0), (0.42, 0.42), (3.0, 1.0), (Double.nan, 0.0)])
    func progressIsClamped(_ raw: Double, _ expected: Double) {
        #expect(card(block: .progress(raw, label: nil)).block == .progress(expected, label: nil))
    }

    /// Empty blocks not rendered: block with no content is equivalent to nil
    @Test func emptyBlocksDisappear() {
        for b: Card.Block in [.text([]), .log([]), .facts([]), .checklist([])] {
            #expect(card(block: b).block == nil)
        }
    }
}

/// Red card and danger only belong to egress guard: external plugins cannot forge them (CLAUDE.md hard rule "External plugins are trusted but restricted")
@Suite struct CardTrust {
    @Test func onlyGuardMayRaiseViolation() {
        #expect(card(.violation, source: .exitGuard).outcome == .violation)
        #expect(card(.violation, source: .claudeCode).outcome == .attention)
        #expect(card(.violation).outcome == .attention)
    }

    /// Green only for nominal egress: external plugins cannot emit "Egress recovered"
    @Test func onlyGuardMayRecover() {
        #expect(card(.recovered, source: .exitGuard).outcome == .recovered)
        #expect(card(.recovered).outcome == .done)
        #expect(card(.recovered, source: .claudeCode).outcome == .done)
    }
}

/// At most two buttons, titles as short as short value (ntfy actions, Adaptive Cards ActionSet)
@Suite struct CardButtons {
    @Test func atMostTwoShortButtons() {
        let long = String(repeating: "b", count: 100)
        let buttons = (1...4).map { Card.Button(title: "\($0)\(long)", action: .activate(bundleID: "com.example.app")) }
        let c = Card(source: .claudeCode, title: "t", outcome: .done, buttons: buttons)
        #expect(c.buttons.count == 2)
        #expect(c.buttons.allSatisfy { $0.title.count == Card.maxValue })
    }
}
