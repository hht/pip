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

/// docs/ui.md「卡片」1、3：一个先进先出队列，一次放一张，卡放出来那一刻才响
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

    /// 鼠标停在卡上暂停，移开从剩下的时间继续
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

    /// 悬停按卡算：换上来的卡照常倒计时，鼠标移进它才停。否则点掉一张卡后鼠标不动，下一张就一直不收（docs/ui.md「卡片」）
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

/// docs/ui.md「卡片」2：还没放的、同一个会话的旧卡被它后来的卡原地替换
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

    /// 外部插件同组的卡只留最新（照 terminal-notifier `-group`）；组名只在一个插件里算数
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

/// docs/ui.md「卡片」4、5 和红卡那一层
@Suite struct AlertLayer {
    /// 违规开始：正在放的卡回到队首，红卡先放满一次停留，再接着放队列（不再响），放完回到红卡
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

    /// 不常驻的红卡放满一次停留就收起，算用户关掉了这一次
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

    /// 回到 healthy（或别处记下关掉了）：红卡撤掉；盖在上面的卡放完不再回到红卡
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

    /// 红卡已经挂着：不重弹、不重响
    @Test func raisingHeldAlertAgainChangesNothing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("a"), now: at(10))
        #expect(q.raiseAlert(persistent: true, seconds: 6, now: at(11)) == silent)
        #expect(q.showing == .notice("a"))
    }

    /// 恢复卡说的是上一次违规：新违规一开始就作废，不论排着还是正在放
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

    /// 悬停暂停中的卡被违规打断，重放时从完整时长重新算
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

/// docs/ui.md「卡片」2：介入卡说的是此刻的状态，过期就撤，正在放也一样
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

    /// 完成卡说的是已经发生的事，不撤
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

/// docs/ui.md「卡片」8：熄屏或锁屏时台面上的卡停住，新来的卡不放、不响，回来接着放
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

    /// 红卡照样挂上（状态要对），但 Basso 等回来再响；红卡的第一次停留也从回来起算
    @Test func alertRaisedWhileAwaySoundsOnReturn() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        #expect(q.raiseAlert(persistent: true, seconds: 6, now: at(1)) == silent)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.setAway(false, now: at(30)) == sound)
        #expect(q.deadline(now: at(30)) == at(36))
    }

    /// 违规在离开期间已经恢复：回来不再补响
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

    /// 常驻红卡放完第一次后锁屏，锁屏期间来的卡解锁后马上盖上去、响
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


/// 外部插件的卡不盖红卡（CLAUDE.md 硬规则「插件」）：红卡挂着时排着，内置的卡照常插队放，红卡撤了再放
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
        // 内置的卡越过它先放
        #expect(q.post(notice("claude"), now: at(8)) == sound)
        #expect(q.showing == .notice("claude"))
        _ = q.tick(now: at(14))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.deadline(now: at(14)) == nil)
        // 红卡撤了才轮到它
        #expect(q.clearAlert(now: at(20)) == sound)
        #expect(q.showing == .notice("ext"))
    }

    /// 正在放的外部卡被新违规打断：回到队里，红卡放完第一次也不出来
    @Test func interruptedByViolationKeepsWaiting() {
        var q = Queue()
        _ = q.post(external("ext"), now: t0)
        _ = q.raiseAlert(persistent: true, seconds: 6, now: at(1))
        _ = q.tick(now: at(7))
        #expect(q.showing == .alert(persistent: true))
        _ = q.dismiss(now: at(8))
        #expect(q.showing == .notice("ext"))
    }

    /// 排着时过了插件说的过期时刻：轮到它时不放、不响，放下一张
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

/// 恢复卡说的是守卫的事：排在违规期间攒下的外部卡前面，内置卡之后
@Suite struct RecoveredBeforeExternal {
    @Test func recoveredJumpsAheadOfExternal() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, seconds: 6, now: t0)
        _ = q.post(Queue.Notice(card: "ext", key: nil, seconds: 6, externalPluginID: "ext"), now: at(1))
        _ = q.post(Queue.Notice(card: "恢复", key: .recovered, seconds: 4), now: at(2))
        _ = q.clearAlert(now: at(2))
        #expect(q.showing == .notice("恢复"))
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("ext"))
    }
}

/// 外部插件每个至多排 3 张：红卡挂久了，撤掉后不该补放一长串，也不该把内置的卡压在后面
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

    /// 正在放的那张不算在排着的里面
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

/// 关掉一个插件：它排着的、正在放的卡都撤（docs/ui.md「卡片」）
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

/// 活动的卡原地刷新（照 ActivityKit 不带 alert 的 update）：换内容，不重放、不响、不重新倒计时
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
