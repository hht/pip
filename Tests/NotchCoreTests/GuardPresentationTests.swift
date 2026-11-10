import Foundation
import Testing
import GuardCore
import MascotCore
@testable import NotchCore

let violatedAt = Date(timeIntervalSince1970: 1_000)

/// Guard round result; unknown without reason means "initial round checking"
func display(_ verdict: Verdict, unknown: UnknownReason? = nil, since: Date = violatedAt) -> GuardDisplay {
    GuardDisplay(verdict: verdict, checkedAt: verdict == .unknown && unknown == nil ? nil : violatedAt,
                 unknownReason: unknown, violatedSince: verdict == .violated ? since : nil)
}

/// docs/egress-guard.md "Visual Rendering", docs/mascot.md §2: Guard visual representation and red card request
@Suite struct GuardPresentationTests {
    @Test(arguments: [
        (display(.healthy), GuardPresentation.Status.healthy, GuardPresentation.Tone.healthy, Look.idle),
        (display(.egressMismatch), .mismatch, .mismatch, .mismatch),
        (display(.unknown, unknown: .offline), .offline, .unknown, .offline),
        // Probe failed does not change look, shows gray ring on right ear
        (display(.unknown, unknown: .probeFailed), .probeFailed, .unknown, .idle),
        // Just launched, first round still checking: gray ring, look unchanged
        (GuardDisplay.checking, .checking, .unknown, .idle),
        (display(.violated), .violated, .violated, .danger),
    ])
    func status(_ d: GuardDisplay, _ status: GuardPresentation.Status, _ tone: GuardPresentation.Tone, _ look: Look) {
        let p = GuardPresentation(d, dismissedViolationSince: nil)
        #expect(p.status == status && p.tone == tone && p.look == look)
    }

    @Test func alertOnlyWhileViolated() {
        #expect(GuardPresentation(display(.violated), dismissedViolationSince: nil).wantsAlert)
        for d in [display(.healthy), display(.egressMismatch), display(.unknown, unknown: .offline), .checking] {
            #expect(!GuardPresentation(d, dismissedViolationSince: nil).wantsAlert)
        }
    }

    /// User dismissed instance: same instance no longer requests red card; Pip remains danger, tone remains violated
    @Test func dismissedViolation() {
        let dv = GuardPresentation(display(.violated), dismissedViolationSince: .some(violatedAt))
        #expect(!dv.wantsAlert && dv.status == .violated && dv.tone == .violated && dv.look == .danger)
        // New violation instance still requests red card
        let next = GuardPresentation(display(.violated, since: violatedAt + 60), dismissedViolationSince: .some(violatedAt))
        #expect(next.wantsAlert)
    }
}
