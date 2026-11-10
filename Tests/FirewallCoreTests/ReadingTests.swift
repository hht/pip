import Foundation
import Testing
@testable import FirewallCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let passed = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: true)
private let noTunnel = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: false)

private func read(_ mode: FirewallStatus.Mode, scope: FirewallRules.Scope? = .everyone, check: FirewallCheck? = passed, ago: TimeInterval = 5,
                  trialEndsAt: Date? = nil, failed: [PFStep] = []) -> FirewallReading {
    FirewallReading(installed: true, summary: .read(FirewallStatus(mode: mode, scope: scope, trialEndsAt: trialEndsAt, check: check,
                                                                   failedSteps: failed, checkedAt: now.addingTimeInterval(-ago))), now: now)
}

/// App only trusts fresh status summary; only official rules and fully-passed on count as "Protected" (docs/firewall.md §2, §4)
@Suite struct FirewallReadingRules {
    @Test func protectedOnlyWhenOnFreshOfficialAndChecked() {
        #expect(read(.on) == .on(problem: nil))
        #expect(read(.on, scope: .testTable) == .on(problem: .testRules))
        // scope is nil: rule reload failed in that round, anchor does not have this version, not test rules
        #expect(read(.on, scope: nil) == .on(problem: .rulesNotLoaded))
        // Tunnel interface missing: Clash TUN not enabled or interface name wrong; in this case everything is blocked, reported separately
        #expect(read(.on, check: noTunnel) == .on(problem: .tunnelMissing))
        let pfStopped = FirewallCheck(pfEnabled: false, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: true)
        #expect(read(.on, check: pfStopped) == .on(problem: .checkFailed))
        // Interface missing and pf stopped: nothing is blocked, cannot say "everything blocked"
        let pfStoppedNoTunnel = FirewallCheck(pfEnabled: false, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: false)
        #expect(read(.on, check: pfStoppedNoTunnel) == .on(problem: .checkFailed))
        let emptyAnchorNoTunnel = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: false, evaluations: nil, evaluationsGrowing: nil, tunnelPresent: false)
        #expect(read(.on, check: emptyAnchorNoTunnel) == .on(problem: .checkFailed))
        #expect(read(.on, check: nil) == .on(problem: .checkFailed))
    }

    @Test func trialShowsDeadline() {
        let end = now.addingTimeInterval(80)
        #expect(read(.trial, trialEndsAt: end) == .trial(endsAt: end, problem: nil))
        #expect(read(.trial, check: noTunnel, trialEndsAt: end) == .trial(endsAt: end, problem: .tunnelMissing))
        #expect(read(.trial) == .trial(endsAt: nil, problem: nil))
    }

    /// Summary claiming open not updated for 30 seconds (3 rounds): daemon uninstalled, crashed, or rescue script just ran; status uncertain
    @Test(arguments: [FirewallStatus.Mode.trial, .on])
    func staleOpenSummaryIsUnknown(_ mode: FirewallStatus.Mode) {
        #expect(read(mode, ago: 31) == .unknown(.stale))
        // Clock dialed backward: summary timestamp too far in future is not trusted either
        #expect(read(mode, ago: -31) == .unknown(.stale))
        #expect(read(mode, ago: 29) != .unknown(.stale))
        #expect(read(mode, ago: 30) != .unknown(.stale))
    }

    /// Daemon does not run when off: freshness ignored
    @Test func offIgnoresFreshness() {
        #expect(read(.off, check: nil, ago: 3600) == .off(problem: nil))
    }

    /// Flushing rules or releasing references failed: may still block while off, must be visible
    @Test func failedStepsAreShown() {
        #expect(read(.off, check: nil, failed: [.flush]) == .off(problem: .failedSteps))
        // When off, failing only to release reference: rules already flushed, leftover reference does not affect connectivity, daemon no longer runs
        #expect(read(.off, check: nil, failed: [.release]) == .off(problem: nil))
        #expect(read(.on, failed: [.load]) == .on(problem: .failedSteps))
    }

    /// "Keep" offered only when trial is completely healthy: missing interface blocks external network, keeping it would persist blackout across reboots. Test rules do not count as protected, but can still be kept
    @Test func keepOnlyWhenTrialIsHealthy() {
        #expect(read(.trial).canKeep)
        #expect(read(.trial, scope: .testTable).canKeep)
        #expect(!read(.trial, check: noTunnel).canKeep)
        #expect(!read(.trial, check: nil).canKeep)
        #expect(!read(.trial, scope: nil).canKeep)
        #expect(!read(.trial, failed: [.load]).canKeep)
        #expect(!read(.on).canKeep)
        #expect(!read(.trial, ago: 31).canKeep)
    }

    /// Switch toggled on: in trial, on, and uncertain states, allowing user to click "Off". Missing summary is also uncertain: daemon may be blocking while failing to write summary
    @Test func switchedOn() {
        #expect(read(.trial).switchedOn && read(.on, check: noTunnel).switchedOn)
        #expect(FirewallReading(installed: true, summary: .missing, now: now).switchedOn)
        #expect(FirewallReading(installed: true, summary: .unreadable, now: now).switchedOn)
        #expect(read(.on, ago: 31).switchedOn)
        #expect(!read(.off).switchedOn && !read(.off, failed: [.flush]).switchedOn && !read(.stateUnreadable).switchedOn)
        #expect(!FirewallReading(installed: false, summary: .missing, now: now).switchedOn)
    }

    @Test func boundaryCases() {
        #expect(FirewallReading(installed: false, summary: .missing, now: now) == .notInstalled)
        // Freshly installed, first round not written yet; or rescue script partially cleaned up
        #expect(FirewallReading(installed: true, summary: .missing, now: now) == .unknown(.noSummary))
        #expect(FirewallReading(installed: true, summary: .unreadable, now: now) == .unknown(.unreadable))
        // When state file unreadable, daemon treated as off and flushed rules: switch should be off, otherwise clicking "Off" has no effect
        #expect(read(.stateUnreadable) == .off(problem: .stateUnreadable))
        // Not installed but leftover summary exists (partially uninstalled): treat as installed so user can see it and retry uninstall
        #expect(FirewallReading(installed: false, summary: .read(FirewallStatus(mode: .on, scope: .everyone, check: passed, checkedAt: now)), now: now)
                == .on(problem: nil))
    }
}

/// Actual verbatim summary written by daemon on real machine (test rules, after keep): format and interpretation match
@Suite struct FirewallReadingRealSummary {
    @Test func testRulesOnIsNotProtected() throws {
        let json = #"{"check":{"anchorPointPresent":true,"evaluations":40851,"evaluationsGrowing":true,"pfEnabled":true,"rulesLoaded":true,"tunnelPresent":true},"checkedAt":"2026-11-01T00:46:05Z","failedSteps":[],"mode":"on","scope":"testTable"}"#
        let status = try FirewallStatus.decode(Data(json.utf8))
        let now = status.checkedAt.addingTimeInterval(3)
        #expect(FirewallReading(installed: true, summary: .read(status), now: now) == .on(problem: .testRules))
        var official = status
        official.scope = .everyone
        #expect(FirewallReading(installed: true, summary: .read(official), now: now) == .on(problem: nil))
    }
}

/// When switch reflects summary after enable, keep, disable: summary precision is seconds, daemon exits after finishing round on disable
@Suite struct FirewallCommandSettling {
    /// Counted from click time (password prompt takes seconds), summary written in subsequent round is trusted
    @Test func summaryAfterCommandStartSettles() {
        let started = Date(timeIntervalSince1970: 1_800_000_000.6)
        let round = Date(timeIntervalSince1970: 1_800_000_004) // Second precision only
        #expect(FirewallReading.settled(checkedAt: round, commandStarted: started, now: round.addingTimeInterval(0.5)))
        #expect(!FirewallReading.settled(checkedAt: Date(timeIntervalSince1970: 1_800_000_000), commandStarted: started, now: round))
    }

    /// Daemon failed to start: settles after 3 rounds, switch will not stay locked indefinitely
    @Test func givesUpAfterFreshness() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!FirewallReading.settled(checkedAt: nil, commandStarted: started, now: started.addingTimeInterval(29)))
        #expect(FirewallReading.settled(checkedAt: nil, commandStarted: started, now: started.addingTimeInterval(31)))
    }
}
