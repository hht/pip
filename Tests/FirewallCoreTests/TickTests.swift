import Testing
@testable import FirewallCore

private let rules = FirewallRules(tunnel: "utun1024", directory: "/nk")!
private let token = "1864012227745836441"
/// System pfd reference (on macOS 26.5 reference persists after pfd exits, docs/firewall.md §6)
private let pfdToken = "12184426722627826779"

/// Snapshot of pf state: whether anchor is empty, and tokens present in pfctl -s References
private func pf(empty: Bool, tokens: Set<String>? = [pfdToken, token]) -> PFSnapshot {
    PFSnapshot(anchorEmpty: empty, tokens: tokens)
}

@Suite struct Tick {
    /// Load rules before obtaining reference: if pf was stopped, rules are already in place when enabled
    @Test func trialLoadsRulesThenEnablesPF() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(s.tick(at: at(101), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [.load(rules), .enable])
    }

    /// Does nothing once loaded and reference acquired: reloading every round resets Evaluations (breaking verification), re-running -E every round accumulates references
    @Test func steadyStateDoesNothing() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: rules) == [])
    }

    /// Reloads if rules were flushed by external action (root pfctl -F, main ruleset reloaded), keeping existing reference
    @Test func reloadsWhenAnchorWasEmptied() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: true), rules: rules) == [.load(rules)])
    }

    /// Reloads with new rules if tunnel interface name changes
    @Test func reloadsWhenRulesChange() {
        var s = steadyTrial()
        let other = FirewallRules(tunnel: "utun7", directory: "/nk")!
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: other) == [.load(other)])
    }

    /// Do not re-run -E when token is unknown: reference is already held, extra -E would add duplicate tokens
    @Test func unknownTokenIsNotReEnabled() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        _ = s.tick(at: at(101), pf: pf(empty: true), rules: rules)
        s.record(.load(rules))
        s.record(.enable, token: nil)
        #expect(s.reference == .unknownToken)
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: rules) == [])
    }

    /// If token missing from list immediately after -E (number mismatch between interfaces), treat as unknown; otherwise daemon would assume reference missing and run -E repeatedly
    @Test func tokenMissingFromTheListRightAfterEnableIsUnknown() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        _ = s.tick(at: at(101), pf: pf(empty: true, tokens: [pfdToken]), rules: rules)
        s.record(.load(rules))
        s.record(.enable, token: token)
        s.confirmReference(liveTokens: [pfdToken])
        #expect(s.reference == .unknownToken)
        #expect(s.tick(at: at(111), pf: pf(empty: false, tokens: [pfdToken]), rules: rules) == [])
    }

    /// If reference list unreadable immediately after -E, trust token reported by -E for verification next round
    @Test func unreadableListRightAfterEnableKeepsTheToken() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        s.record(.enable, token: token)
        s.confirmReference(liveTokens: nil)
        #expect(s.reference == .held(token: token))
    }

    /// An unknown token reference can only be detected as revoked via "pf stopped": once stopped, assume revoked and re-enable next round rather than remaining disabled
    @Test func unknownTokenIsDroppedWhenPFIsDisabled() throws {
        var s = FirewallState(bootSession: boot)
        s.reference = .unknownToken
        _ = s.check(mainRules: "", anchorRules: "", info: "", interfaces: "", tunnel: "utun1024")
        #expect(s.reference == .unknownToken) // Unreadable info does not count as stopped
        _ = s.check(mainRules: "", anchorRules: "", info: "Status: Disabled\n", interfaces: "", tunnel: "utun1024")
        #expect(s.reference == nil)
    }

    /// If external pfctl -d revoked all references (docs/firewall.md §6): re-run -E once our token vanishes rather than assuming it's held
    @Test func reEnablesWhenOurReferenceIsGone() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: false, tokens: []), rules: rules) == [.enable])
    }

    /// When references list is unreadable, preserve status: avoid -E unless certain it's gone (better to miss one than leak accumulating references)
    @Test func unreadableReferencesKeepsTheToken() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: false, tokens: nil), rules: rules) == [])
        #expect(s.reference == .held(token: token))
    }
}

extension Tick {
    /// Flush rules before releasing reference: releasing may stop pf, rules must be cleared first to prevent re-activation if someone else enables pf later
    @Test func offFlushesThenReleases() {
        var s = steadyTrial()
        s.disable()
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: rules) == [.flush, .release(token: token)])
        s.record(.flush)
        s.record(.release(token: token))
        #expect(s.tick(at: at(121), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [])
    }

    /// Only release tokens still present in pf: revoked tokens may have been reassigned to other callers
    @Test func offDoesNotReleaseAGoneToken() {
        var s = steadyTrial()
        s.disable()
        #expect(s.tick(at: at(111), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [])
        #expect(s.reference == nil)
    }

    /// Defer release to next round if reference list is unreadable
    @Test func offWaitsWhenReferencesAreUnreadable() {
        var s = steadyTrial()
        s.disable()
        #expect(s.tick(at: at(111), pf: pf(empty: true, tokens: nil), rules: rules) == [])
        #expect(s.reference == .held(token: token))
    }

    /// Expiry triggers rollback unconditionally, even without App running
    @Test func expiredTrialRollsBack() {
        var s = steadyTrial()
        #expect(s.tick(at: at(220), pf: pf(empty: false), rules: rules) == [.flush, .release(token: token)])
        #expect(s.mode == .off)
    }

    /// Kernel rules and references are gone across reboot: `on` reloads and re-acquires reference (old token not in list, so not released)
    @Test func onAfterBootReloadsAndReEnables() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [.load(rules), .enable])
        #expect(s.mode == .on)
    }

    /// `trial` becomes `off` across reboot, without attempting to release previous boot token
    @Test func trialAfterBootIsOffAndDoesNotReleaseTheOldToken() {
        var s = steadyTrial()
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [])
        #expect(s.mode == .off)
        #expect(s.reference == nil)
    }

    /// Unreadable boot ID (sysctl failed): uncertain if rebooted, trial safely defaults to off; preserves reference and recorded boot ID to avoid losing active reference or pairing old token with wrong boot ID
    @Test func unreadableBootSessionEndsTheTrialButKeepsTheReference() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111, boot: nil), pf: pf(empty: false, tokens: nil), rules: rules) == [.flush])
        #expect(s.mode == .off)
        #expect(s.reference == .held(token: token))
        #expect(s.bootSession == boot)
    }

    /// Boot ID changed but reference remains in list (false boot ID reading): retain active reference to avoid redundant -E runs on each misdetection
    @Test func spuriousBootChangeKeepsALiveReference() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        #expect(s.tick(at: at(120, boot: "OTHER-BOOT"), pf: pf(empty: false), rules: rules) == [.load(rules)])
        #expect(s.reference == .held(token: token))
    }

    /// Unknown token cannot be verified in list: revoked if boot ID changes, re-running -E for on
    @Test func bootChangeDropsAnUnknownToken() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        s.reference = .unknownToken
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true), rules: rules) == [.load(rules), .enable])
    }

    /// Boot change with unreadable references: cannot keep old token with new boot ID (rescue script keys on boot ID and would -X previous boot token); on must re-acquire via -E
    @Test func bootChangeWithUnreadableReferencesDropsTheOldToken() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true, tokens: nil), rules: rules) == [.load(rules), .enable])
        #expect(s.reference == nil)
    }

    /// Evaluations counter starts from 0 after reload: reset baseline to avoid false "evaluations not growing" alert immediately after reload
    @Test func reloadResetsTheEvaluationBaseline() {
        var s = steadyTrial()
        let anchor = { (n: Int) in "pass all\n  [ Evaluations: \(n)  Packets: 0 ]\n" }
        func check(_ n: Int) -> Bool? {
            s.check(mainRules: "anchor \"com.apple/*\" all\n", anchorRules: anchor(n), info: "Status: Enabled\n",
                    interfaces: "utun1024", tunnel: "utun1024").evaluationsGrowing
        }
        #expect(check(500) == nil)
        #expect(check(900) == true)
        s.record(.load(rules))
        #expect(check(40) == nil)
    }
}

/// Steady state trial: rules loaded and reference acquired
private func steadyTrial() -> FirewallState {
    var s = FirewallState(bootSession: boot)
    try! s.enable(at: at(100))
    _ = s.tick(at: at(101), pf: pf(empty: true, tokens: [pfdToken]), rules: rules)
    s.record(.load(rules))
    s.record(.enable, token: token)
    return s
}
