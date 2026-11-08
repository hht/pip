import Foundation
import Testing
@testable import FirewallCore

@Suite struct StatusFormat {
    @Test func roundTrips() throws {
        let check = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 7055,
                                  evaluationsGrowing: true, tunnelPresent: true)
        let s = FirewallStatus(mode: .trial, scope: .testTable, trialEndsAt: Date(timeIntervalSince1970: 1_793_440_000),
                               check: check, failedSteps: [.enable], checkedAt: Date(timeIntervalSince1970: 1_793_439_900))
        #expect(try FirewallStatus.decode(s.encoded()) == s)
    }

    /// Missing fields use defaults, extra fields are ignored; timestamp is ISO 8601
    @Test func decodesWithDefaults() throws {
        let s = try FirewallStatus.decode(Data(#"{"checkedAt":"2026-10-31T04:05:00Z","future":1}"#.utf8))
        #expect(s == FirewallStatus(mode: .off, scope: nil, checkedAt: Date(timeIntervalSince1970: 1_793_419_500)))
    }
}
