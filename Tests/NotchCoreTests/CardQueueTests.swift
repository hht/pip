import Foundation
import Testing
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private typealias Queue = CardQueue<String>

private func notice(_ card: String, session: Int32? = nil, seconds: TimeInterval = 6, lapses: Bool = false) -> Queue.Notice {
    Queue.Notice(card: card, key: session.map { .session($0) }, seconds: seconds, lapses: lapses)
}

private let sound = Queue.Change(sound: true)
private let silent = Queue.Change()

/// docs/ui.md "Cards" 1, 3: FIFO queue, shows one card at a time, sounds when presented
@Suite struct NoticeQueue {
    @Test func postedNoticeShowsAndSounds() {
        var q = Queue()
        #expect(q.post(notice("a"), now: t0) == sound)
        #expect(q.showing == .notice("a"))
    }

    @Test func noticeCollapsesAfterItsSeconds() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.deadline(now: t0) == at(6))
        #expect(q.tick(now: at(5.9)) == silent)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(6))
        #expect(q.showing == nil)
        #expect(q.deadline(now: at(6)) == nil)
    }

    @Test func laterNoticeWaitsAndSoundsWhenShown() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.post(notice("b"), now: at(1)) == silent)
        #expect(q.showing == .notice("a"))
        #expect(q.tick(now: at(6)) == sound)
        #expect(q.showing == .notice("b"))
        _ = q.tick(now: at(12))
        #expect(q.showing == nil)
    }

    @Test func dismissShowsNext() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(notice("b"), now: t0)
        #expect(q.dismiss(now: at(1)) == sound)
        #expect(q.showing == .notice("b"))
        #expect(q.deadline(now: at(1)) == at(7))
    }

    /// Mouse hover pauses countdown; resumes from remaining time when leaving
    @Test func hoverPausesCountdown() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(2))
        #expect(q.deadline(now: at(10)) == nil)
        _ = q.tick(now: at(10))
        #expect(q.showing == .notice("a"))
        _ = q.setHovering(false, now: at(10))
        _ = q.tick(now: at(13.9))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(14))
        #expect(q.showing == nil)
    }

    /// Hover evaluated per card: next card starts unhovered, pauses only when mouse enters it (docs/ui.md "Cards")
    @Test func nextCardStartsUnhovered() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(notice("b"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.dismiss(now: at(2))
        #expect(q.showing == .notice("b"))
        #expect(q.deadline(now: at(2)) == at(8))
    }

    @Test func cardAfterCollapseStartsUnhovered() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.dismiss(now: at(2))
        _ = q.post(notice("b"), now: at(10))
        #expect(q.deadline(now: at(10)) == at(16))
    }

    @Test func alertStartsUnhovered() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.raiseAlert(persistent: true, seconds: 6, now: at(2))
        #expect(q.deadline(now: at(2)) == at(8))
    }
}

/// docs/ui.md "Cards" 2: Unpresented older card from same session replaced in-place by newer card
@Suite struct SameSessionKeepsLatest {
    @Test func waitingNoticeIsReplacedInPlace() {
        var q = Queue()
        _ = q.post(notice("a", session: 1), now: t0)
        _ = q.post(notice("b", session: 2), now: t0)
        _ = q.post(notice("d", session: 3), now: t0)
        _ = q.post(notice("c", session: 2), now: t0)
        var shown: [Queue.Showing?] = [q.showing]
        for s in [6.0, 12, 18] {
            _ = q.tick(now: at(s))
            shown.append(q.showing)
        }
        #expect(shown == [.notice("a"), .notice("c"), .notice("d"), nil])
    }

    @Test func showingNoticeIsNotReplaced() {
        var q = Queue()
        _ = q.post(notice("a", session: 1), now: t0)
        _ = q.post(notice("b", session: 1), now: t0)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("b"))
    }

    @Test func noticesWithoutKeyAreNeverReplaced() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(notice("b"), now: t0)
        _ = q.post(notice("c"), now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("b"))
    }

    /// External plugin group keeps latest only (following terminal-notifier `-group`); group scoped to plugin
    @Test func sameGroupOfSamePluginIsReplaced() {
        func grouped(_ card: String, _ plugin: String, _ name: String) -> Queue.Notice {
            Queue.Notice(card: card, key: .group(plugin: plugin, name: name), seconds: 6, externalPluginID: plugin)
        }
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(grouped("b", "terminal", "tty1"), now: t0)
        _ = q.post(grouped("c", "build", "tty1"), now: t0)
        _ = q.post(grouped("d", "terminal", "tty1"), now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("d"))
        _ = q.tick(now: at(12))
        #expect(q.showing == .notice("c"))
    }
}

/// docs/ui.md "Cards" 4, 5 and alert base layer
@Suite struct AlertLayer {
    /// Violation begins: active notice returns to front of queue, red card presented first, then queue resumes silently, returning to red card
    @Test func violationPreemptsAndInterruptedNoticeReplaysSilently() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.raiseAlert(persistent: true, seconds: 6, now: at(1)) == sound)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.tick(now: at(7)) == silent)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(13))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.deadline(now: at(13)) == nil)
        _ = q.tick(now: at(100))
        #expect(q.showing == .alert(persistent: true))
    }

    @Test func noticeWaitsDuringAlertsFirstShowing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        #expect(q.post(notice("a"), now: at(1)) == silent)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.tick(now: at(6)) == sound)
        #expect(q.showing == .notice("a"))
    }

    @Test func noticeCoversHeldAlertAfterItsFirstShowing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.post(notice("a"), now: at(20)) == sound)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(26))
        #expect(q.showing == .alert(persistent: true))
    }

    /// Non-persistent red card times out after initial linger, treated as user dismissal
    @Test func nonPersistentAlertTimesOutAsDismissed() {
        var q = Queue()
        _ = q.raiseAlert(persistent: false, seconds: 6, now: t0)
        _ = q.post(notice("a"), now: at(1))
        #expect(q.tick(now: at(6)) == Queue.Change(sound: true, alertDismissed: true))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(12))
        #expect(q.showing == nil)
    }

    @Test func dismissingAlertReportsIt() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        #expect(q.dismiss(now: at(1)) == Queue.Change(alertDismissed: true))
        #expect(q.showing == nil)
    }

    /// Returned to healthy (or dismissed): red card removed, subsequent notices do not return to red card
    @Test func clearedAlertDoesNotComeBack() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("a"), now: at(10))
        #expect(q.clearAlert(now: at(11)) == silent)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(16))
        #expect(q.showing == nil)
    }

    @Test func clearingShownAlertShowsNext() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.post(notice("a"), now: at(1))
        #expect(q.clearAlert(now: at(2)) == sound)
        #expect(q.showing == .notice("a"))
    }

    /// Red card already active: does not re-raise or re-sound
    @Test func raisingHeldAlertAgainChangesNothing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("a"), now: at(10))
        #expect(q.raiseAlert(persistent: true, seconds: 6, now: at(11)) == silent)
        #expect(q.showing == .notice("a"))
    }

    /// Recovery card pertains to prior violation: discarded when new violation begins
    @Test(arguments: [false, true])
    func newViolationDropsRecoveredCard(_ persistent: Bool) {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(Queue.Notice(card: "recovered", key: .recovered, seconds: 4), now: t0)
        _ = q.raiseAlert(persistent: persistent, seconds: 6, now: at(1))
        _ = q.tick(now: at(7))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(13))
        #expect(q.showing == (persistent ? .alert(persistent: true) : nil))
    }

    @Test func newViolationDropsShowingRecoveredCard() {
        var q = Queue()
        _ = q.post(Queue.Notice(card: "recovered", key: .recovered, seconds: 4), now: t0)
        _ = q.raiseAlert(persistent: true, seconds: 6, now: at(1))
        _ = q.tick(now: at(7))
        #expect(q.showing == .alert(persistent: true))
    }

    /// Hover-paused notice interrupted by violation replays with full duration
    @Test func interruptedPausedNoticeReplaysFullLength() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(5))
        _ = q.raiseAlert(persistent: true, seconds: 6, now: at(10))
        _ = q.setHovering(false, now: at(10))
        _ = q.tick(now: at(16))
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(16)) == at(22))
    }
}

@Suite struct QueueEdges {
    @Test func waitingRecoveredCardIsReplaced() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(Queue.Notice(card: "r1", key: .recovered, seconds: 4), now: t0)
        _ = q.post(Queue.Notice(card: "r2", key: .recovered, seconds: 4), now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("r2"))
        _ = q.tick(now: at(10))
        #expect(q.showing == nil)
    }

    @Test func dismissWithNothingShownChangesNothing() {
        var q = Queue()
        #expect(q.dismiss(now: t0) == silent)
        #expect(q.showing == nil)
    }
}

/// docs/ui.md "Cards" 2: Intervention card represents ephemeral prompt state; withdrawn if lapsed, even while active
@Suite struct LapsingNotices {
    @Test func laterCardOfSameSessionReplacesShowingLapsingNotice() {
        var q = Queue()
        _ = q.post(notice("approval", session: 1, lapses: true), now: t0)
        #expect(q.post(notice("done", session: 1), now: at(1)) == sound)
        #expect(q.showing == .notice("done"))
        #expect(q.deadline(now: at(1)) == at(7))
    }

    @Test func withdrawRemovesWaitingAndShowingLapsingNotices() {
        var q = Queue()
        _ = q.post(notice("x", session: 2), now: t0)
        _ = q.post(notice("approval", session: 1, lapses: true), now: t0)
        #expect(q.withdraw(.session(1), now: at(1)) == silent)
        _ = q.tick(now: at(6))
        #expect(q.showing == nil)

        _ = q.post(notice("question", session: 1, lapses: true), now: at(10))
        _ = q.post(notice("y", session: 3), now: at(10))
        #expect(q.withdraw(.session(1), now: at(11)) == sound)
        #expect(q.showing == .notice("y"))
    }

    /// Done notice represents completed event, not withdrawn
    @Test func withdrawKeepsNonLapsingNotices() {
        var q = Queue()
        _ = q.post(notice("done", session: 1), now: t0)
        _ = q.withdraw(.session(1), now: at(1))
        #expect(q.showing == .notice("done"))
    }

    @Test func withdrawingNoticeOverHeldAlertReturnsToAlert() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("approval", session: 1, lapses: true), now: at(10))
        _ = q.withdraw(.session(1), now: at(11))
        #expect(q.showing == .alert(persistent: true))
    }
}

/// docs/ui.md "Cards" 8: Screen sleep/lock pauses active card, queues new cards silently, resumes on wake
@Suite struct ScreenAway {
    @Test func awayFreezesShowingNoticeAndHoldsNewOnes() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setAway(true, now: at(2))
        _ = q.tick(now: at(100))
        #expect(q.showing == .notice("a"))
        #expect(q.post(notice("b"), now: at(50)) == silent)
        #expect(q.setAway(false, now: at(100)) == silent)
        #expect(q.deadline(now: at(100)) == at(104))
        #expect(q.tick(now: at(104)) == sound)
        #expect(q.showing == .notice("b"))
    }

    @Test func noticePostedWhileAwayShowsAndSoundsOnReturn() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        #expect(q.post(notice("a"), now: at(1)) == silent)
        #expect(q.showing == nil)
        #expect(q.setAway(false, now: at(10)) == sound)
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(10)) == at(16))
    }

    /// Red card raised while away (state updated), Basso deferred until wake; initial linger starts on return
    @Test func alertRaisedWhileAwaySoundsOnReturn() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        #expect(q.raiseAlert(persistent: true, seconds: 6, now: at(1)) == silent)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.setAway(false, now: at(30)) == sound)
        #expect(q.deadline(now: at(30)) == at(36))
    }

    /// Violation recovered while away: no sound on wake
    @Test func alertClearedWhileAwayNeverSounds() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        _ = q.raiseAlert(persistent: true, seconds: 6, now: at(1))
        _ = q.clearAlert(now: at(2))
        #expect(q.setAway(false, now: at(30)) == silent)
        #expect(q.showing == nil)
    }

    @Test func hoveringAndAwayPauseIndependently() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.setAway(true, now: at(2))
        _ = q.setAway(false, now: at(10))
        #expect(q.deadline(now: at(10)) == nil)
        _ = q.setHovering(false, now: at(10))
        #expect(q.deadline(now: at(10)) == at(15))
    }

    /// Notice queued during sleep over held persistent alert shows and sounds on wake
    @Test func noticePostedOverHeldAlertWhileAwayShowsOnReturn() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.setAway(true, now: at(10))
        _ = q.post(notice("a"), now: at(11))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.setAway(false, now: at(20)) == sound)
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(20)) == at(26))
    }
}


/// External plugin cards do not cover red alert (CLAUDE.md hard rule "Plugins"): queued during alert, built-in cards take precedence, external cards shown after alert clears
@Suite struct ExternalNoticesWaitForAlert {
    private func external(_ card: String) -> Queue.Notice {
        Queue.Notice(card: card, key: nil, seconds: 6, externalPluginID: "ext")
    }

    @Test func waitsBehindHangingAlert() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        #expect(q.post(external("ext"), now: at(7)) == silent)
        #expect(q.showing == .alert(persistent: true))
        // Built-in card takes precedence
        #expect(q.post(notice("claude"), now: at(8)) == sound)
        #expect(q.showing == .notice("claude"))
        _ = q.tick(now: at(14))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.deadline(now: at(14)) == nil)
        // External card shown only after alert clears
        #expect(q.clearAlert(now: at(20)) == sound)
        #expect(q.showing == .notice("ext"))
    }

    /// Active external card interrupted by new violation returns to queue, deferred until alert clears
    @Test func interruptedByViolationKeepsWaiting() {
        var q = Queue()
        _ = q.post(external("ext"), now: t0)
        _ = q.raiseAlert(persistent: true, seconds: 6, now: at(1))
        _ = q.tick(now: at(7))
        #expect(q.showing == .alert(persistent: true))
        _ = q.dismiss(now: at(8))
        #expect(q.showing == .notice("ext"))
    }

    /// Notice expiring while waiting is discarded when queue advances
    @Test func staleWhileWaitingIsDropped() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.post(Queue.Notice(card: "old", key: nil, seconds: 6, externalPluginID: "ext", staleAt: at(60)), now: at(1))
        _ = q.post(Queue.Notice(card: "new", key: nil, seconds: 6, externalPluginID: "ext", staleAt: at(600)), now: at(2))
        #expect(q.clearAlert(now: at(60)) == sound)
        #expect(q.showing == .notice("new"))
        _ = q.tick(now: at(66))
        #expect(q.showing == nil)
    }
}

/// Recovery card pertains to guard: prioritizes before external cards queued during violation, after built-in cards
@Suite struct RecoveredBeforeExternal {
    @Test func recoveredJumpsAheadOfExternal() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.post(Queue.Notice(card: "ext", key: nil, seconds: 6, externalPluginID: "ext"), now: at(1))
        _ = q.post(Queue.Notice(card: "recovered", key: .recovered, seconds: 4), now: at(2))
        _ = q.clearAlert(now: at(2))
        #expect(q.showing == .notice("recovered"))
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("ext"))
    }
}

/// At most 3 queued cards per external plugin: prevents backlog after extended violation
@Suite struct ExternalWaitingCap {
    private func external(_ card: String, _ plugin: String = "build") -> Queue.Notice {
        Queue.Notice(card: card, key: nil, seconds: 6, externalPluginID: plugin)
    }

    @Test func keepsNewestThreePerPlugin() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        for i in 1...5 { _ = q.post(external("b\(i)"), now: at(1)) }
        _ = q.post(external("t1", "terminal"), now: at(1))
        _ = q.clearAlert(now: at(2))
        var shown: [String] = []
        for i in 0..<5 {
            if case .notice(let c)? = q.showing { shown.append(c) }
            _ = q.tick(now: at(2 + 6 * Double(i + 1)))
        }
        #expect(shown == ["b3", "b4", "b5", "t1"])
    }

    /// Card on stage is not counted in waiting queue
    @Test func showingCardIsNotCounted() {
        var q = Queue()
        for i in 1...4 { _ = q.post(external("b\(i)"), now: t0) }
        var shown: [String] = []
        for i in 0..<4 {
            if case .notice(let c)? = q.showing { shown.append(c) }
            _ = q.tick(now: at(6 * Double(i + 1)))
        }
        #expect(shown == ["b1", "b2", "b3", "b4"])
    }
}

/// Disabling a plugin: withdraws its queued and active cards (docs/ui.md "Cards")
@Suite struct DiscardNotices {
    @Test func discardsWaitingAndShowing() {
        var q = Queue()
        _ = q.post(notice("a", session: 1), now: t0)
        _ = q.post(Queue.Notice(card: "ext", key: nil, seconds: 6, externalPluginID: "build"), now: t0)
        _ = q.post(notice("b", session: 2), now: t0)
        #expect(q.discard(where: { $0.key == .session(1) || $0.key == .session(2) }, now: at(1)) == sound)
        #expect(q.showing == .notice("ext"))
        _ = q.tick(now: at(7))
        #expect(q.showing == nil)
    }

    @Test func discardingNothingChangesNothing() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.discard(where: { $0.externalPluginID == "build" }, now: at(1)) == silent)
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(1)) == at(6))
    }
}

/// In-place activity card updates (following ActivityKit update without alert): update content without replay, sound, or reset countdown
@Suite struct UpdateInPlace {
    private func activity(_ card: String) -> Queue.Notice {
        Queue.Notice(card: card, key: .activity(plugin: "dl", id: "x"), seconds: 6, externalPluginID: "dl")
    }

    @Test func updatesShowingCard() {
        var q = Queue()
        _ = q.post(activity("10%"), now: t0)
        let found = q.update("60%", key: .activity(plugin: "dl", id: "x"))
        #expect(found)
        #expect(q.showing == .notice("60%"))
        #expect(q.deadline(now: at(3)) == at(6))
    }

    @Test func updatesWaitingCard() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(activity("10%"), now: t0)
        let found = q.update("60%", key: .activity(plugin: "dl", id: "x"))
        #expect(found)
        #expect(q.tick(now: at(6)) == sound)
        #expect(q.showing == .notice("60%"))
    }

    @Test func absentKeyIsNotPosted() {
        var q = Queue()
        let found = q.update("60%", key: .activity(plugin: "dl", id: "x"))
        #expect(!found)
        #expect(q.showing == nil)
    }
}
