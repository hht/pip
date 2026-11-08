import Foundation
import NotchCore

/// Step in an activity, admitted by `InboxGate`
public struct ActivityUpdate: Sendable {
    public var plugin: String
    public var id: String
    public var event: Message.Activity.Event
    public var at: Date
    public var staleAt: Date?
    /// Present card (rate limit passed)
    public var alert: Bool
    /// Content at this moment: panel row and presented card are both derived from this
    public var card: Card
}

/// Answers: which activities are currently active from external plugins, what row each draws in panel, plugin urgency, which card to present or update in-place.
/// Follows ActivityKit: start / update / end, newest by timestamp (out-of-order old messages do not overwrite new ones), max 8 hours, removed when `staleAt` reached.
/// Pure state machine: fed admitted `ActivityUpdate` and current time; does not read directory, runs no timers (App calls `expire` on `deadline`).
/// @see https://developer.apple.com/documentation/activitykit/activity
public struct ActivityBoard: Sendable {
    /// ActivityKit: an activity can run at most 8 hours from start
    /// @see https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
    public static let maxAge: TimeInterval = 8 * 3600
    /// Max active activities per plugin: panel section shows at most 5 rows, more suggests a runaway script
    public static let maxPerPlugin = 5

    /// Card to present or refresh: App first attempts in-place refresh (`CardQueue.update`), presents only if not found and `alert` is true
    public struct CardChange: Equatable, Sendable {
        public var card: Card
        public var key: CardQueue<Card>.Key
        public var alert: Bool
        /// Expiration specified in message: discard if not shown by then
        public var staleAt: Date?
    }

    /// Latest step in an activity: only admitted if newer. When timestamps match, follows step order (start < update < end): if script ends within 1s, end still tears down row
    private struct Step: Comparable, Sendable {
        var at: Date
        var order: Int

        /// Moment activity ended: once ended, only a newer start can reopen it
        static func end(at: Date) -> Step { Step(at: at, order: 2) }

        private init(at: Date, order: Int) {
            self.at = at
            self.order = order
        }

        init(_ u: ActivityUpdate) {
            at = u.at
            order = switch u.event {
            case .start: 0
            case .update: 1
            case .end: 2
            }
        }

        static func < (a: Step, b: Step) -> Bool { (a.at, a.order) < (b.at, b.order) }
    }

    private struct Live: Sendable {
        var started: Date
        var last: Step
        var expires: Date
        var cardID: UUID
        var card: Card
    }

    private var live: [CardQueue<Card>.Key: Live] = [:]
    /// Ended activities (end, expired, evicted) -> end step: only a newer start can reopen it, update and end are dropped (following ActivityKit).
    /// Only tracked for `maxAge`, older messages are already rejected by `InboxGate`
    private var ended: [CardQueue<Card>.Key: Step] = [:]

    public init() {}

    /// Returns card to present or refresh; returns nil for old messages (not newer than latest step)
    public mutating func apply(_ u: ActivityUpdate, now: Date) -> CardChange? {
        let key = CardQueue<Card>.Key.activity(plugin: u.plugin, id: u.id)
        ended = ended.filter { now.timeIntervalSince($0.value.at) < Self.maxAge }
        let step = Step(u)
        if let last = live[key]?.last {
            guard step > last else { return nil }
        } else if let end = ended[key] {
            guard u.event == .start, step > end else { return nil }
        }
        let old = live[key]
        let cardID = old?.cardID ?? UUID()
        let card = Self.card(u.card, id: cardID)
        switch u.event {
        case .end:
            live[key] = nil
            ended[key] = step
        case .start, .update:
            // Update without seeing start (App started late, start expired) treated as start; start restarts timer. Ended already intercepted above
            let started = u.event == .start || old == nil ? u.at : old!.started
            live[key] = Live(started: started, last: step,
                             expires: min(u.staleAt ?? .distantFuture, started.addingTimeInterval(Self.maxAge)), cardID: cardID, card: card)
            dropOldest(u.plugin)
            // Older than active ones, evicted immediately on entry: not shown in panel, no card presented
            guard live[key] != nil else { return nil }
        }
        return CardChange(card: card, key: key, alert: u.alert, staleAt: u.staleAt)
    }

    /// Deadline reached: remove expired rows
    public mutating func expire(now: Date) {
        for (key, l) in live where now >= l.expires {
            live[key] = nil
            ended[key] = .end(at: now)
        }
    }

    /// Expiration timestamp of earliest activity; nil if no activities
    public var deadline: Date? { live.values.map(\.expires).min() }

    /// Plugin disabled in settings
    public mutating func remove(plugin: String) {
        live = live.filter { $0.key.plugin != plugin }
    }

    /// Sorted by start time, ties broken by id; updates do not reorder rows (consistent session row)
    public func rows(for plugin: String) -> [PanelRow] {
        live.compactMap { key, l -> (id: String, live: Live)? in
            guard case .activity(plugin, let id) = key else { return nil }
            return (id, l)
        }
        .sorted { ($0.live.started, $0.id) < ($1.live.started, $1.id) }
        .map { id, l in
            let c = l.card
            let symbol = if case .plugin(_, _, let s) = c.source { s } else { preconditionFailure("Activities only come from external plugins") }
            let indicator: PanelRow.Indicator = if c.outcome == .attention {
                .attention
            } else if case .progress(let p, _)? = c.block {
                .progress(p)
            } else {
                .working
            }
            return PanelRow(id: "\(plugin):\(id)", icon: .symbol(symbol), title: c.title, subtitle: c.subtitle, indicator: indicator,
                            trailing: c.value.map(PanelRow.Trailing.value) ?? .since(l.started), action: c.action)
        }
    }

    /// Highest urgency among active activities: attention requires look, otherwise active; calm if no activities
    public func urgency(for plugin: String) -> PluginStatus.Urgency {
        let mine = live.filter { $0.key.plugin == plugin }.values
        if mine.contains(where: { $0.card.outcome == .attention }) { return .attention }
        return mine.isEmpty ? .calm : .active
    }

    private mutating func dropOldest(_ plugin: String) {
        let mine = live.filter { $0.key.plugin == plugin }
        guard mine.count > Self.maxPerPlugin, let oldest = mine.min(by: { $0.value.last < $1.value.last }) else { return }
        live[oldest.key] = nil
        ended[oldest.key] = .end(at: oldest.value.last.at)
    }

    /// Recreate card for same activity, reusing id from first card
    private static func card(_ c: Card, id: UUID) -> Card {
        Card(id: id, source: c.source, title: c.title, subtitle: c.subtitle, value: c.value, outcome: c.outcome, block: c.block,
             action: c.action, buttons: c.buttons)
    }
}
