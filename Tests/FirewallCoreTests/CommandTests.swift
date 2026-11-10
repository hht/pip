import Testing
@testable import FirewallCore

let boot = "B5E97D3E-1F68-4627-B43C-2257F22F12DB"
func at(_ seconds: Int64, boot session: String? = boot) -> Moment {
    Moment(bootSession: session, now: MonotonicTime(milliseconds: seconds * 1000))
}

@Suite struct Commands {
    @Test func enableStartsATwoMinuteTrial() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(s.mode == .trial(deadline: MonotonicTime(milliseconds: 220_000)))
    }

    /// State machine only allows off -> trial for enabling: clicking enable during trial cannot postpone the deadline
    @Test func enableOnlyFromOff() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.notOff) { try s.enable(at: at(150)) }
        #expect(s.mode == .trial(deadline: MonotonicTime(milliseconds: 220_000)))
    }

    @Test func keepBeforeDeadlineTurnsOn() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        try s.keep(at: at(219))
        #expect(s.mode == .on)
    }

    /// Must rollback on expiry: clicking "Keep" before daemon runs the round cannot salvage an expired trial
    @Test func keepAtDeadlineIsRefusedAndRollsBack() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.notInTrial) { try s.keep(at: at(220)) }
        #expect(s.mode == .off)
    }

    @Test func keepWhenOffIsRefused() {
        var s = FirewallState(bootSession: boot)
        #expect(throws: FirewallCommandError.notInTrial) { try s.keep(at: at(100)) }
        #expect(s.mode == .off)
    }

    /// At boot, trial is always treated as off: trial from previous boot cannot be kept, even if deadline hasn't elapsed against new monotonic clock
    @Test func keepATrialFromThePreviousBootIsRefused() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.notInTrial) { try s.keep(at: at(5, boot: "OTHER-BOOT")) }
        #expect(s.mode == .off)
        #expect(s.bootSession == "OTHER-BOOT")
    }

    /// Commands do not read reference list: old token is always revoked across boots, and must not be saved to disk paired with the new boot ID (which happens when release fails on shutdown and re-enabled after reboot)
    @Test func commandAfterBootDropsTheOldToken() throws {
        var s = FirewallState(bootSession: boot)
        s.reference = .held(token: "1864012227745836441")
        try s.enable(at: at(5, boot: "OTHER-BOOT"))
        #expect(s.reference == nil)
    }

    /// Enable and keep both throw error when boot ID is unreadable (the next round would treat trial as off anyway, silently rolling back without explaining why);
    /// references and recorded boot ID are preserved: losing an active reference means it can never be released
    @Test func commandsRefuseAnUnreadableBootSession() throws {
        var s = FirewallState(bootSession: boot)
        s.reference = .held(token: "1864012227745836441")
        #expect(throws: FirewallCommandError.bootSessionUnknown) { try s.enable(at: at(100, boot: nil)) }
        #expect(s.mode == .off)
        #expect(s.reference == .held(token: "1864012227745836441"))
        #expect(s.bootSession == boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.bootSessionUnknown) { try s.keep(at: at(110, boot: nil)) }
        #expect(s.mode == .off)
    }

    @Test(arguments: [false, true])
    func disableTurnsOffFromTrialOrOn(kept: Bool) throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        if kept { try s.keep(at: at(110)) }
        s.disable()
        #expect(s.mode == .off)
    }
}
