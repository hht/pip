import Testing
@testable import MascotCore

/// Shared clock for all Pips: besides blinks and idle motions (IdleDirectorTests), manages gaze re-centering, drowsiness, dizziness (docs/mascot.md §2, §5)
@Suite struct MascotClockTests {
    /// Falls asleep when mouse stays away from notch for 120s; wakes immediately upon approach
    @Test func drowsyAfterMouseStaysAway() {
        var c = MascotClock(seed: 1, now: 0)
        #expect(c.nextWake <= MascotClock.drowsyAfter)
        _ = c.tick(now: MascotClock.drowsyAfter - 1, mouseNear: false)
        #expect(!c.drowsy)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: false)
        #expect(c.drowsy)
        c.mouseMoved(near: true, looking: false, now: 200)
        #expect(!c.drowsy)
        // Rescheduled from waking moment
        _ = c.tick(now: 200 + MascotClock.drowsyAfter - 1, mouseNear: false)
        #expect(!c.drowsy)
    }

    /// Stationary mouse resting near notch (no move events) still keeps awake
    @Test func stillMouseNearNotchKeepsAwake() {
        var c = MascotClock(seed: 1, now: 0)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: true)
        #expect(!c.drowsy)
        #expect(c.nextWake <= 2 * MascotClock.drowsyAfter)
    }

    /// Distant mouse moves do not count as approach
    @Test func farMovesDoNotCount() {
        var c = MascotClock(seed: 1, now: 0)
        c.mouseMoved(near: false, looking: true, now: 100)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: false)
        #expect(c.drowsy)
    }

    /// Does not wake for drowsiness while already asleep
    @Test func noDrowsyWakeWhileAsleep() {
        var c = MascotClock(seed: 1, now: 0)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: false)
        for _ in 0..<5 { _ = c.tick(now: c.nextWake, mouseNear: false) }
        #expect(c.drowsy)
    }

    /// When tracking mouse: re-centers 4s after stopping; suppresses idle motions during this time
    @Test func gazeRestsAfterMouseStops() {
        var c = MascotClock(seed: 1, now: 0)
        c.mouseMoved(near: false, looking: true, now: 1)
        #expect(c.nextWake <= 1 + Choreography.gazeRestAfter)
        #expect(!c.tick(now: 1 + Choreography.gazeRestAfter - 0.01, mouseNear: false).gazeRested)
        let t = c.tick(now: 1 + Choreography.gazeRestAfter, mouseNear: false)
        #expect(t.gazeRested)
        #expect(!t.cues.contains { if case .idle = $0 { true } else { false } })
        // Re-center emitted only once
        #expect(!c.tick(now: 1 + Choreography.gazeRestAfter + 0.1, mouseNear: false).gazeRested)
    }

    /// Disable mouse tracking: cancels waiting for re-center
    @Test func endGazeCancelsRest() {
        var c = MascotClock(seed: 1, now: 0)
        c.mouseMoved(near: false, looking: true, now: 1)
        c.endGaze()
        #expect(!c.tick(now: 1 + Choreography.gazeRestAfter, mouseNear: false).gazeRested)
    }

    /// Poking Pip makes it dizzy for 1.6s
    @Test func pokeMakesDizzyForAWhile() {
        var c = MascotClock(seed: 1, now: 0)
        c.poke(now: 10)
        #expect(c.dizzy)
        #expect(c.nextWake <= 10 + MascotClock.dizzyFor)
        _ = c.tick(now: 10 + MascotClock.dizzyFor - 0.01, mouseNear: false)
        #expect(c.dizzy)
        _ = c.tick(now: 10 + MascotClock.dizzyFor, mouseNear: false)
        #expect(!c.dizzy)
    }

    /// Poking again while dizzy: resets from this poke
    @Test func pokeAgainExtends() {
        var c = MascotClock(seed: 1, now: 0)
        c.poke(now: 10)
        c.poke(now: 11)
        _ = c.tick(now: 10 + MascotClock.dizzyFor, mouseNear: false)
        #expect(c.dizzy)
    }

    /// When all Pips become invisible while dizzy (e.g. left ear Pip omitted when collapsed): dizziness ends before clock suspends, not persisting to mask other looks when restored
    @Test func suspendEndsDizzy() {
        var c = MascotClock(seed: 1, now: 0)
        c.poke(now: 10)
        c.suspend()
        #expect(!c.dizzy)
    }

    /// Clock wakes per nextWake, blinks emitted normally
    @Test func blinksStillCome() {
        var c = MascotClock(seed: 1, now: 0)
        var blinks = 0
        while c.nextWake < 30 {
            blinks += c.tick(now: c.nextWake, mouseNear: true).cues.filter { if case .blink = $0 { true } else { false } }.count
        }
        #expect(blinks >= 4)
    }
}

/// Dizzy and sleeping overlay on plugin looks (docs/mascot.md §2 "Priority"): guard > dizzy > agent > sleeping > idle
@Suite struct MascotOverlay {
    @Test func dizzyBeatsAgentAndSleep() {
        for look in [Look.idle, .working, .longTurn, .question, .approval, .finished] {
            #expect(look.shown(drowsy: true, dizzy: true) == .dizzy)
        }
    }

    /// Sign looks (guard alerts, error cards) are not masked by dizziness
    @Test func signsBeatDizzy() {
        for look in [Look.danger, .shielded, .mismatch, .stale, .offline, .error] {
            #expect(look.shown(drowsy: true, dizzy: true) == look)
        }
    }

    /// Only idle look falls asleep
    @Test func onlyIdleFallsAsleep() {
        #expect(Look.idle.shown(drowsy: true, dizzy: false) == .sleeping)
        #expect(Look.working.shown(drowsy: true, dizzy: false) == .working)
        #expect(Look.idle.shown(drowsy: false, dizzy: false) == .idle)
    }
}
