import Foundation
import Testing
@testable import AgentCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Session with pid 1 enters state at t0 + at seconds; sessionId is "s<pid>"
private func session(_ state: AgentState, at: TimeInterval = 0, pid: Int32 = 1, started: TimeInterval = -3600, id: String? = nil) -> Session {
    Session(pid: pid, processStart: t0.addingTimeInterval(started), sessionId: id ?? "s\(pid)", cwd: "/p\(pid)",
            state: state, stateSince: t0.addingTimeInterval(at))
}

/// Mod turn file: latest finished main turn for session corresponding to pid, ending at t0 + at seconds
private func report(_ turnId: String, _ outcome: TurnOutcome, at: TimeInterval = 1, pid: Int32 = 1, background: Int = 0) -> TurnReport {
    TurnReport(sessionId: "s\(pid)", ended: EndedTurn(turnId: turnId, outcome: outcome, backgroundAgents: background, at: t0.addingTimeInterval(at)))
}

/// Feeds sessions in sequence (each read at its stateSince), returning events at each step
private func feed(_ board: inout AgentBoard, _ sessions: Session...) -> [AgentEvent?] {
    sessions.map { board.update($0, at: $0.stateSince) }
}

/// Feeds turn reports in sequence, all read at t0 + at
private func feed(_ board: inout AgentBoard, at: TimeInterval = 2, _ reports: TurnReport...) -> [AgentEvent?] {
    reports.map { board.update($0, at: t0.addingTimeInterval(at)) }
}

/// App starts watching at t0
private func makeBoard() -> AgentBoard { AgentBoard(since: t0) }

/// Turn completion only checks mod turn files (docs/agent-integration.md "How turns end")
@Suite struct TurnEnds {
    @Test func doneTurnIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done)) == [.turnDone(pid: 1)])
    }

    @Test func failedTurnIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .failed)) == [.turnFailed(pid: 1)])
    }

    @Test func canceledTurnIsQuiet() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .canceled)) == [nil])
    }

    /// Background agents still running on completion: silent; notifies turn done only when the turn reporting their completion finishes
    @Test func doneWithBackgroundAgentsWaitsForTheNextTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done, background: 1), report("t2", .done, at: 5)) == [nil, .turnDone(pid: 1)])
    }

    /// Errors ignore background agents
    @Test func failedWithBackgroundAgentsStillFails() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .failed, background: 2)) == [.turnFailed(pid: 1)])
    }

    /// Same finished turn read twice, notifies only once
    @Test func sameEndedTurnOnce() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done), report("t1", .done)) == [.turnDone(pid: 1), nil])
    }

    /// Queued messages: previous turn finishes, next turn starts immediately; previous turn notifies normally
    @Test func eachEndedTurnIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done), report("t2", .done, at: 3)) == [.turnDone(pid: 1), .turnDone(pid: 1)])
    }

    /// Mid-session takeover: turns ended before watching started do not trigger retroactive notification
    @Test func turnEndedBeforeWatchingIsQuiet() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped))
        #expect(feed(&board, report("t1", .done, at: -5)) == [nil])
    }

    /// First time seeing a turn file, but turn ended after watching started (new session, or first turn after /clear): notifies normally
    @Test func firstReportAfterWatchingIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done, at: 1)) == [.turnDone(pid: 1)])
    }

    /// Turn file arrives before sessions file (/clear hasn't updated sessionId yet): deferred, notifies normally once session matches
    @Test func reportBeforeSessionIsNotLost() {
        var board = makeBoard()
        #expect(feed(&board, report("t1", .done)) == [nil])
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done)) == [.turnDone(pid: 1)])
    }

    /// Does not match any tracked session (e.g. VS Code session): silent
    @Test func reportWithoutSessionIsQuiet() {
        var board = makeBoard()
        #expect(feed(&board, report("t1", .done, pid: 9)) == [nil])
    }

    /// /clear changed id, process exited, resumed via claude --resume <old id> in same run: old turn file already read, does not re-notify
    @Test func resumedSessionDoesNotReplayOldTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done)) == [.turnDone(pid: 1)])
        _ = feed(&board, session(.stopped, at: 3, id: "s9"))
        board.remove(pid: 1)
        _ = feed(&board, session(.stopped, at: 5, pid: 2, id: "s1"))
        #expect(feed(&board, at: 6, report("t1", .done)) == [nil])
    }

    /// Turn file with no ended turn yet
    @Test func noEndedTurnIsQuiet() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(board.update(TurnReport(sessionId: "s1", ended: nil), at: t0) == nil)
    }

    /// Transition to stopped in sessions file is not turn completion (errors, cancellations, and background agent finishes all briefly flicker idle)
    @Test func stoppingIsNotATurnEnd() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.stopped, at: 9)) == [nil, nil, nil])
    }
}

/// Needs you (sessions file)
@Suite struct NeedingYou {
    /// Returning to working ends intervention (intervention card is dismissed)
    @Test func needsYouThenWorking() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.needsYou(.approval), at: 2),
                     session(.needsYou(.approval), at: 2), session(.working, at: 5))
                == [nil, nil, .needsYou(.approval, pid: 1), nil, .needsYouEnded(pid: 1)])
    }

    /// Pressing Esc in approval prompt, or closing idle dialog: transition to stopped also ends intervention
    @Test func stoppingWhileNeedingYouEndsNeed() {
        var board = makeBoard()
        #expect(feed(&board, session(.working), session(.needsYou(.question), at: 2), session(.stopped, at: 3))
                == [nil, .needsYou(.question, pid: 1), .needsYouEnded(pid: 1)])
        var idle = makeBoard()
        #expect(feed(&idle, session(.stopped), session(.needsYou(.question), at: 1), session(.stopped, at: 2))
                == [nil, .needsYou(.question, pid: 1), .needsYouEnded(pid: 1)])
    }

    /// Switching from approval to question remains in needsYou, does not ping again
    @Test func switchingNeedDoesNotPingAgain() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped), session(.needsYou(.approval), at: 1), session(.needsYou(.question), at: 2))
                == [nil, .needsYou(.approval, pid: 1), nil])
    }
}

/// When App starts or first discovers a file, it is already mid-turn (docs/agent-integration.md "Mid-turn takeover")
@Suite struct PickingUpMidTurn {
    /// Already waiting for you: does not ping, ends intervention normally afterwards
    @Test func needingYouAtFirstSightDoesNotPing() {
        var board = makeBoard()
        #expect(feed(&board, session(.needsYou(.approval)), session(.working, at: 3)) == [nil, .needsYouEnded(pid: 1)])
    }

    /// Work start uses statusUpdatedAt from file, not time read by App
    @Test func pickedUpTurnStartsWhenFileSays() {
        var board = makeBoard()
        _ = board.update(session(.working), at: t0.addingTimeInterval(590))
        #expect(board.activity(at: t0.addingTimeInterval(600)) == .longTurn)
    }

    @Test func stoppedAtFirstSightIsQuiet() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped)) == [nil])
    }
}

/// Process gone: removed from list, not considered stopped, does not notify (docs/agent-integration.md "Processes exiting")
@Suite struct SessionsGoing {
    @Test func removedSessionIsForgotten() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        board.remove(pid: 1)
        #expect(board.sessions.isEmpty)
        #expect(feed(&board, report("t1", .done)) == [nil])
    }

    /// pid reused: differing start time indicates distinct process, resets work start baseline
    @Test func reusedPidIsANewSession() {
        var board = makeBoard()
        _ = feed(&board, session(.working, at: -590), session(.working, at: 5, started: 4))
        #expect(board.activity(at: t0.addingTimeInterval(10)) == .working)
    }
}

/// docs/mascot.md §2 "Priority" agent tier; long turn at 10 minutes from docs/agent-integration.md, finished for 5.2s from docs/mascot.md §2
@Suite struct Activity {
    @Test func nothingTrackedIsNil() {
        #expect(makeBoard().activity(at: t0) == nil)
    }

    @Test func stoppedSessionAddsNothing() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped))
        #expect(board.activity(at: t0.addingTimeInterval(1)) == nil)
    }

    /// Triggers at 10 minutes exactly (instant transition at time boundary ensures nextChange accuracy); waiting time is included
    @Test func longTurnAfterTenMinutesSinceWorkStart() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped, at: -1), session(.working), session(.needsYou(.approval), at: 100), session(.working, at: 500))
        #expect(board.activity(at: t0.addingTimeInterval(599.9)) == .working)
        #expect(board.activity(at: t0.addingTimeInterval(600)) == .longTurn)
    }

    @Test func needsYouShowsItsKind() {
        var board = makeBoard()
        _ = feed(&board, session(.needsYou(.question)))
        #expect(board.activity(at: t0.addingTimeInterval(1)) == .question)
    }

    /// Finished persists for 5.2s after turn completion, then clears
    @Test func finishedLastsFivePointTwoSeconds() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.stopped, at: 10))
        _ = feed(&board, at: 10, report("t1", .done, at: 10))
        #expect(board.activity(at: t0.addingTimeInterval(15.1)) == .finished)
        #expect(board.activity(at: t0.addingTimeInterval(15.2)) == nil)
    }

    /// Failed turns do not show finished
    @Test func failedIsNotFinished() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.stopped, at: 10))
        _ = feed(&board, at: 10, report("t1", .failed, at: 10))
        #expect(board.activity(at: t0.addingTimeInterval(11)) == nil)
    }

    /// Highest session priority wins among multiple sessions
    @Test func highestSessionWins() {
        var board = makeBoard()
        _ = feed(&board, session(.working, pid: 1), session(.needsYou(.question), pid: 2), session(.needsYou(.approval), pid: 3),
                 session(.working, at: 1, pid: 4), session(.stopped, at: 2, pid: 4))
        _ = feed(&board, at: 2, report("t1", .done, at: 2, pid: 4))
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .approval)
        board.remove(pid: 3)
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .question)
        board.remove(pid: 2)
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .working)
        board.remove(pid: 1)
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .finished)
    }
}

/// When no new files arrive, activity changes at future timestamps due to elapsed time: App schedules only this single timer
@Suite struct NextChange {
    @Test func nothingPendingIsNil() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped), session(.needsYou(.question), pid: 2))
        #expect(board.nextChange(after: t0) == nil)
    }

    @Test func workingBecomesLongTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working, at: 10))
        #expect(board.nextChange(after: t0.addingTimeInterval(10)) == t0.addingTimeInterval(610))
        #expect(board.nextChange(after: t0.addingTimeInterval(610)) == nil)
    }

    @Test func earliestOfFinishedAndLongTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working, at: -598, pid: 1), session(.working, pid: 2), session(.stopped, at: 1, pid: 2))
        _ = feed(&board, at: 1, report("t1", .done, at: 1, pid: 2))
        #expect(board.nextChange(after: t0.addingTimeInterval(1)) == t0.addingTimeInterval(2))
        #expect(board.nextChange(after: t0.addingTimeInterval(2)) == t0.addingTimeInterval(6.2))
        #expect(board.nextChange(after: t0.addingTimeInterval(6.2)) == nil)
    }
}

/// Panel session list: only active tracked sessions; sorted by process start time, stable row order across state changes
@Suite struct SessionList {
    @Test func listsTrackedSessionsByProcessStart() {
        var board = makeBoard()
        _ = feed(&board, session(.working, pid: 7, started: -10), session(.stopped, pid: 3, started: -5),
                 session(.needsYou(.approval), pid: 5, started: -20))
        #expect(board.sessions.map(\.pid) == [5, 7, 3])
        _ = board.update(session(.stopped, at: 9, pid: 5, started: -20), at: t0.addingTimeInterval(9))
        #expect(board.sessions.map(\.pid) == [5, 7, 3])
        #expect(board.sessions.first?.state == .stopped)
        board.remove(pid: 7)
        #expect(board.sessions.map(\.pid) == [5, 3])
    }

    /// procStart has second precision: ordered by pid when started in same second for stable sorting
    @Test func sameSecondOrdersByPid() {
        var board = makeBoard()
        _ = feed(&board, session(.working, pid: 9, started: -5), session(.working, pid: 2, started: -5))
        #expect(board.sessions.map(\.pid) == [2, 9])
    }
}

/// Intervention ended: session needing you returns to working, stopped, or process exits (docs/ubiquitous-language.md)
@Suite struct NeedsYouEnds {
    @Test func processGoneWhileNeedingYouEndsNeed() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.needsYou(.question), at: 1))
        #expect(board.remove(pid: 1) == .needsYouEnded(pid: 1))
    }

    @Test func processGoneOtherwiseSaysNothing() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(board.remove(pid: 1) == nil)
        #expect(board.remove(pid: 1) == nil)
    }

    /// pid reused: if previous process was in needsYou, emits intervention ended
    @Test func reusedPidEndsOldNeed() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.needsYou(.approval), at: 1))
        #expect(board.update(session(.working, at: 5, started: 4), at: t0.addingTimeInterval(5)) == .needsYouEnded(pid: 1))
    }
}

