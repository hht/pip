import AppKit
import SwiftUI
import Testing
import MascotCore
import NotchCore
@testable import Notchkeeper

/// Pip look and alert sound for each outcome (docs/ui.md "Card" 7, docs/agent-integration.md "Alerts").
@Suite struct CardAppearance {
    @Test(arguments: [
        (Card.Outcome.done, Look.finished, "Glass" as String?),
        (.recovered, .finished, "Glass"),
        (.failed, .error, "Funk"),
        (.question, .question, "Ping"),
        (.approval, .approval, "Ping"),
        (.attention, .question, "Ping"),
        (.info, .idle, nil),
        (.violation, .danger, "Basso"),
    ])
    func lookAndSound(_ outcome: Card.Outcome, _ look: Look, _ sound: String?) {
        let card = Card(source: .exitGuard, title: "t", outcome: outcome)
        #expect(card.look == look && card.sound.map { $0 as String } == sound)
    }

    /// Body text only recognizes inline formatting: links and images are stripped (actions only via clicking cards and buttons; image paths not accepted).
    @Test @MainActor func markdownDropsLinksAndImages() {
        let s = CardBlockView.markdown("**bold** [link](https://example.com) ![image](file:///etc/hosts)")
        #expect(s.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        #expect(s.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }
}
