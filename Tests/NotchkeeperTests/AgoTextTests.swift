import Foundation
import Testing
@testable import Notchkeeper

/// "Ago text" only describes the past: freshly written guard status and timestamps equal to or slightly ahead of now should never say "in 0 sec."
@Suite struct AgoTextTense {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let en = Locale(identifier: "en_US")
    private let zh = Locale(identifier: "zh-Hans")

    @Test(arguments: [0.0, 0.4, 3])
    func nowOrLaterIsPast(_ ahead: TimeInterval) {
        let s = AgoText.string(now.addingTimeInterval(ahead), now: now, locale: en)
        #expect(s.hasSuffix("ago") && !s.hasPrefix("in "), "\(s)")
        #expect(AgoText.string(now.addingTimeInterval(ahead), now: now, locale: zh).hasSuffix("\u{524D}"))
    }

    @Test func pastStaysAsIs() {
        #expect(AgoText.string(now.addingTimeInterval(-300), now: now, locale: en) == "5 min. ago")
    }
}
