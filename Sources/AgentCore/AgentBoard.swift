import Foundation

/// Events that warrant notification (docs/agent-integration.md "Notifications")
public enum AgentEvent: Equatable, Sendable {
    /// Main turn completed, all background agents finished: completion card + Glass
    case turnDone(pid: Int32)
    /// Main turn failed: failure card + Funk
    case turnFailed(pid: Int32)
    /// Entered state requiring intervention: intervention card + Ping. Switching between question and approval does not re-notify
    case needsYou(AgentState.Need, pid: Int32)
    /// Intervention no longer needed: returned to working, stopped, or process exited (including pid reuse). Dismisses intervention card for this session
    case needsYouEnded(pid: Int32)
}

/// Combined agent activity across all sessions, determining what mascot level should display. Ordered low to high priority (docs/mascot.md §2 "Priority")
public enum AgentActivity: Comparable, Sendable {
    case finished, working, longTurn, question, approval
}

/// Answers: which sessions are tracked, their current state, and recent notification-worthy events.
/// Two input streams: sessions files track current state, mod turn files track turn outcomes (docs/agent-integration.md "Two sources"), correlated via sessionId.
/// Pure state machine: fed parsed Session, TurnReport, and current timestamp; does not read files, query processes, run timers, or manage Pip/cards.
public struct AgentBoard: Sendable {
    /// pid -> most recently seen session, and start timestamp of current work segment (nil when stopped)
    private var tracked: [Int32: (session: Session, workStart: Date?)] = [:]
    /// sessionId -> most recent turn report matching session. Old ids replaced by /clear are intentionally kept: when resuming via claude --resume <old id> in same app run, the report is recognized as previously seen, avoiding stale cards
    private var reports: [String: TurnReport] = [:]
    /// Timestamp App started watching: turns finished prior are mid-session takeovers, skipping notifications
    private let since: Date
    /// Timestamp until which finished mascot display persists after turn completion
    private var finishedUntil: Date?

    /// Duration in working state after which turn is considered long (docs/agent-integration.md). Inclusive comparison: triggers exactly at time boundary so nextChange matches accurately
    static let longTurnAfter: TimeInterval = 600
    /// Duration finished animation lasts (docs/mascot.md §2)
    static let finishedFor: TimeInterval = 5.2

    public init(since: Date) {
        self.since = since
    }

    public mutating func update(_ session: Session, at now: Date) -> AgentEvent? {
        guard let old = tracked[session.pid], old.session.processStart == session.processStart else {
            // First time seeing this process (including pid reuse) is a takeover: if already working, uses stateSince as workStart without emitting events.
            // If old process was in needsYou upon pid reuse, emits needsYouEnded for old process
            let replaced = tracked[session.pid]
            tracked[session.pid] = (session, session.state == .stopped ? nil : session.stateSince)
            if case .needsYou? = replaced?.session.state { return .needsYouEnded(pid: session.pid) }
            return nil
        }
        var workStart = old.workStart
        var event: AgentEvent?
        switch session.state {
        case .working, .needsYou:
            if workStart == nil { workStart = session.stateSince }
        case .stopped:
            workStart = nil
        }
        switch (old.session.state, session.state) {
        case (.needsYou, .needsYou): break
        case (_, .needsYou(let need)): event = .needsYou(need, pid: session.pid)
        case (.needsYou, _): event = .needsYouEnded(pid: session.pid)
        default: break
        }
        tracked[session.pid] = (session, workStart)
        return event
    }

    /// Turn file updated: notifies when ended turn changes. When seeing turn file for a session for the first time, turns finished prior to App start are takeovers, skipping notification.
    /// Reports not matching any session are ignored temporarily (/clear may precede session update), processed upon subsequent update
    public mutating func update(_ report: TurnReport, at now: Date) -> AgentEvent? {
        guard let pid = tracked.first(where: { $0.value.session.sessionId == report.sessionId })?.key else { return nil }
        let old = reports.updateValue(report, forKey: report.sessionId)
        guard let ended = report.ended, old.map({ $0.ended?.turnId != ended.turnId }) ?? (ended.at > since) else { return nil }
        switch ended.outcome {
        case .done:
            // Background agents still running: wait for turn completion once all finish
            guard ended.backgroundAgents == 0 else { return nil }
            finishedUntil = now.addingTimeInterval(Self.finishedFor)
            return .turnDone(pid: pid)
        case .failed: return .turnFailed(pid: pid)
        case .canceled: return nil
        }
    }

    public func activity(at now: Date) -> AgentActivity? {
        let sessions = tracked.values.compactMap { entry -> AgentActivity? in
            switch entry.session.state {
            case .stopped: return nil
            case .needsYou(.question): return .question
            case .needsYou(.approval): return .approval
            case .working:
                guard let start = entry.workStart else { preconditionFailure("Working session must have a work start time") }
                return now >= start.addingTimeInterval(Self.longTurnAfter) ? .longTurn : .working
            }
        }
        let finished = finishedUntil.map { now < $0 ? [AgentActivity.finished] : [] } ?? []
        return (sessions + finished).max()
    }

    /// Tracked sessions: sorted by process start time (secondary by pid), stable row positioning across state changes
    public var sessions: [Session] {
        tracked.values.map(\.session).sorted { ($0.processStart, $0.pid) < ($1.processStart, $1.pid) }
    }

    /// Next timestamp when activity changes purely due to time without file updates (strictly later than now): becomes longTurn or finished expires. nil if none
    public func nextChange(after now: Date) -> Date? {
        let longTurns = tracked.values.compactMap { entry in
            entry.session.state == .working ? entry.workStart?.addingTimeInterval(Self.longTurnAfter) : nil
        }
        return (longTurns + [finishedUntil].compactMap { $0 }).filter { $0 > now }.min()
    }

    /// Process gone (exit, pid reuse, undecidable): forgets session and turn report, suppressing turn completion notification; emits needsYouEnded if previously in needsYou
    @discardableResult
    public mutating func remove(pid: Int32) -> AgentEvent? {
        guard let old = tracked.removeValue(forKey: pid) else { return nil }
        reports[old.session.sessionId] = nil
        if case .needsYou = old.session.state { return .needsYouEnded(pid: pid) }
        return nil
    }
}
