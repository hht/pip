import Foundation

/// Answers: Which card is currently displayed on the notch, when to swap to the next, and whether to play a cue sound on presentation (docs/ui.md "Cards").
/// Two tiers: Red alert card serves as base layer when active; temporary cards form a FIFO queue shown one at a time, returning to red card when queue finishes. External plugin cards do not present while red card is active; built-in cards take precedence.
/// Pure state machine: fed events and current time; agnostic of card appearance and cue sound, plays no audio, runs no timers (App calls `tick` on `deadline`).
/// Whether red card should be active is determined externally (current state + dismissedViolationSince); this queue only schedules display.
public struct CardQueue<Item: Equatable & Sendable>: Sendable {
    /// Old card with matching key replaced in-place by newer card
    public enum Key: Hashable, Sendable {
        case session(Int32)
        case recovered
        /// Group defined by external plugin: keeps latest within same plugin (following terminal-notifier `-group`)
        case group(plugin: String, name: String)
        /// Card presented by external plugin activity: subsequent updates refresh in-place (`update`)
        case activity(plugin: String, id: String)

        /// External plugin ID for group and activity cards; nil for built-in plugins
        public var plugin: String? {
            switch self {
            case .group(let p, _), .activity(let p, _): return p
            case .session, .recovered: return nil
            }
        }
    }

    /// Max queued cards per external plugin, excess drops oldest: prevents backlog after long red card
    public static var maxWaitingPerPlugin: Int { 3 }

    /// Temporary card notice
    public struct Notice: Equatable, Sendable {
        public var card: Item
        /// nil: never replaced
        public var key: Key?
        /// Display duration ("Card Linger" setting; 4s fixed for recovery card)
        public var seconds: TimeInterval
        /// Represents ephemeral prompt state (intervention card): superseded by newer card from same session or `withdraw`
        public var lapses: Bool
        /// External plugin ID; nil for built-in plugin cards. External cards queue while red card is active (CLAUDE.md hard rule "Plugins")
        public var externalPluginID: String?
        /// Discard if not displayed by this time (stale external messages after extended red card or screen sleep)
        public var staleAt: Date?

        public init(card: Item, key: Key?, seconds: TimeInterval, lapses: Bool = false, externalPluginID: String? = nil, staleAt: Date? = nil) {
            self.card = card
            self.key = key
            self.seconds = seconds
            self.lapses = lapses
            self.externalPluginID = externalPluginID
            self.staleAt = staleAt
        }
    }

    public enum Showing: Equatable, Sendable {
        case notice(Item)
        /// persistent: "Keep red card until nominal"
        case alert(persistent: Bool)
    }

    /// Action required by App after input; check `showing` for current display
    public struct Change: Equatable, Sendable {
        /// Card just presented, should play its cue sound
        public var sound = false
        /// Red card dismissed while violation persists (user clicked x, or non-persistent timed out): App records dismissal
        public var alertDismissed = false

        public init(sound: Bool = false, alertDismissed: Bool = false) {
            self.sound = sound
            self.alertDismissed = alertDismissed
        }
    }

    private struct Entry: Sendable {
        var notice: Notice
        /// Has been presented and sounded (cards re-queued after interruption do not sound again)
        var sounded = false
    }

    private enum Stage: Sendable {
        case notice(Entry)
        case alert
    }

    /// When red card is active (on stage or queued beneath): whether persistent; nil when inactive
    private var alert: Bool?
    private var stage: Stage?
    private var waiting: [Entry] = []
    /// Countdown for card on stage; nil means pinned (persistent red card after initial presentation). Pauses on hover or sleep
    public private(set) var countdown: CardCountdown?
    public private(set) var hovering = false
    /// Screen sleep or lock: new cards queued without sound, countdown paused
    private var away = false
    /// Red card raised while away, plays sound on return
    private var alertSoundDue = false

    public init() {}

    public var showing: Showing? {
        switch stage {
        case .notice(let e): return .notice(e.notice.card)
        case .alert: return alert.map { .alert(persistent: $0) }
        case nil: return nil
        }
    }

    /// Timestamp when card on stage expires; nil if paused or pinned
    public func deadline(now: Date) -> Date? {
        guard let c = countdown, !c.isPaused else { return nil }
        return now.addingTimeInterval(c.remaining(at: now))
    }

    public mutating func post(_ notice: Notice, now: Date) -> Change {
        if case .notice(let e) = stage, e.notice.lapses, let key = notice.key, e.notice.key == key {
            // Active intervention card superseded by new card for same session
            waiting.removeAll { $0.notice.key == key }
            waiting.insert(Entry(notice: notice), at: 0)
            return next(now)
        }
        if let key = notice.key, let i = waiting.firstIndex(where: { $0.notice.key == key }) {
            waiting[i] = Entry(notice: notice)
        } else if notice.key == .recovered {
            // Recovery card pertains to guard: prioritizes before external cards queued during violation
            waiting.insert(Entry(notice: notice), at: waiting.firstIndex { $0.notice.externalPluginID != nil } ?? waiting.endIndex)
        } else {
            waiting.append(Entry(notice: notice))
            if let plugin = notice.externalPluginID, waiting.count(where: { $0.notice.externalPluginID == plugin }) > Self.maxWaitingPerPlugin {
                waiting.remove(at: waiting.firstIndex { $0.notice.externalPluginID == plugin }!)
            }
        }
        return yieldable ? next(now) : Change()
    }

    /// Stage can yield to queued cards: empty, or persistent red card finished initial presentation
    private var yieldable: Bool {
        switch stage {
        case nil: return true
        case .alert: return countdown == nil
        case .notice: return false
        }
    }

    /// New violation begins: active notice returned to front of queue, red card presented for `seconds`, plays Basso (deferred if screen sleeping).
    /// Recovery card from prior violation discarded
    public mutating func raiseAlert(persistent: Bool, seconds: TimeInterval, now: Date) -> Change {
        guard alert == nil else { return Change() }
        alert = persistent
        if case .notice(let e) = stage { waiting.insert(e, at: 0) }
        waiting.removeAll { $0.notice.key == .recovered }
        stage = .alert
        start(seconds, now: now)
        alertSoundDue = away
        return Change(sound: !away)
    }

    /// Red card cleared (returned to healthy, or dismissed elsewhere)
    public mutating func clearAlert(now: Date) -> Change {
        alert = nil
        alertSoundDue = false
        guard case .alert = stage else { return Change() }
        return next(now)
    }

    /// User clicked x on current card
    public mutating func dismiss(now: Date) -> Change {
        switch stage {
        case .notice: return next(now)
        case .alert:
            alert = nil
            alertSoundDue = false
            var change = next(now)
            change.alertDismissed = true
            return change
        case nil: return Change()
        }
    }

    /// Deadline reached: advance to next card (App calls via `deadline`)
    public mutating func tick(now: Date) -> Change {
        guard let c = countdown, c.remaining(at: now) <= 0, let stage else { return Change() }
        switch stage {
        case .notice: return next(now)
        case .alert:
            guard let persistent = alert else { preconditionFailure("Red card must be active when shown on stage") }
            if !persistent { return dismiss(now: now) }
            // Persistent red card finished first run: yield if eligible, else stay
            return next(now)
        }
    }

    /// Session no longer needs intervention: withdraw pending and active intervention cards
    public mutating func withdraw(_ key: Key, now: Date) -> Change {
        waiting.removeAll { $0.notice.key == key && $0.notice.lapses }
        guard case .notice(let e) = stage, e.notice.key == key, e.notice.lapses else { return Change() }
        return next(now)
    }

    /// Discard queued and active cards matching predicate (plugin disabled)
    public mutating func discard(where shouldGo: (Notice) -> Bool, now: Date) -> Change {
        waiting.removeAll { shouldGo($0.notice) }
        guard case .notice(let e) = stage, shouldGo(e.notice) else { return Change() }
        return next(now)
    }

    /// Matching key card in queue or stage: update in-place without replaying, sounding, or restarting countdown; returns if found
    public mutating func update(_ card: Item, key: Key) -> Bool {
        var found = false
        for i in waiting.indices where waiting[i].notice.key == key {
            waiting[i].notice.card = card
            found = true
        }
        if case .notice(var e) = stage, e.notice.key == key {
            e.notice.card = card
            stage = .notice(e)
            found = true
        }
        return found
    }

    /// Mouse hover on card: pause countdown; resume when mouse leaves
    public mutating func setHovering(_ on: Bool, now: Date) -> Change {
        hovering = on
        syncCountdown(now)
        return Change()
    }

    /// Screen sleep or lock (docs/ui.md "Cards" 8): card paused, new cards queued without sound; resumes on wake, pending alert sound plays
    public mutating func setAway(_ on: Bool, now: Date) -> Change {
        guard on != away else { return Change() }
        away = on
        if on {
            syncCountdown(now)
            return Change()
        }
        // Deferred alert sound already played if yieldable
        if yieldable { return next(now) }
        syncCountdown(now)
        defer { alertSoundDue = false }
        return Change(sound: alertSoundDue)
    }

    /// Card enters stage, starts countdown. Hover evaluated per-card: cursor must enter card to pause
    private mutating func start(_ seconds: TimeInterval, now: Date) {
        countdown = CardCountdown(total: seconds, now: now)
        hovering = false
        syncCountdown(now)
    }

    private mutating func syncCountdown(_ now: Date) {
        if hovering || away { countdown?.pause(at: now) } else { countdown?.resume(at: now) }
    }

    /// Next card eligible for stage: skip external cards while red card active
    private var nextIndex: Int? {
        alert == nil ? waiting.indices.first : waiting.firstIndex { $0.notice.externalPluginID == nil }
    }

    /// Card finished: purge expired waiting notices, advance to next notice; fall back to persistent red card (no sound); collapse if empty
    private mutating func next(_ now: Date) -> Change {
        waiting.removeAll { $0.notice.staleAt.map { $0 <= now } ?? false }
        if let i = nextIndex, !away {
            var e = waiting.remove(at: i)
            let sound = !e.sounded
            e.sounded = true
            stage = .notice(e)
            start(e.notice.seconds, now: now)
            return Change(sound: sound)
        }
        stage = alert == nil ? nil : .alert
        countdown = nil
        return Change()
    }
}
