import Foundation
import NotchCore

/// Answers: whether a parsed message is admitted to the notch, as which card, and which replacement group.
/// Unregistered, stale, duplicate, or rate-limited messages are dropped (CLAUDE.md hard rule "Plugins"); enabled/disabled in settings evaluated by App on main thread. Pure state machine: plugin map and current time fed by App, does not read directory
public struct InboxGate: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case unregistered, stale, duplicate, rateLimited
    }

    public struct Admitted: Sendable {
        public var card: Card
        public var key: CardQueue<Card>.Key?
        /// Discard if not displayed by this time (`CardQueue.Notice.staleAt`)
        public var staleAt: Date
    }

    /// At most `limit` cards per `window` seconds per plugin: each card displays ~6s, more would flood the notch
    public static let limit = 6
    public static let window: TimeInterval = 60
    /// Messages older than this are dropped: accumulated while App closed or during red card; stale notifications are unhelpful. `staleAt` can only be earlier, not later
    public static let lifetime: TimeInterval = 10 * 60

    /// Plugin id -> timestamps admitted in window
    private var admitted: [String: [Date]] = [:]
    /// Seen message id -> its expiration: retained until then, same id arriving later treated as new
    private var seen: [UUID: Date] = [:]
    public init() {}

    /// Regular card (`m.activity` is nil)
    public mutating func admit(_ m: Message, plugins: [String: Manifest], now: Date) throws(Rejection) -> Admitted {
        precondition(m.activity == nil, "Activities go through admitActivity")
        let manifest = try registered(m, plugins)
        // Sent timestamp in future (clock skew/misconfiguration) clamped to now: prevents perpetual retention and unbounded growth
        let staleAt = min(m.staleAt ?? .distantFuture, min(m.at, now).addingTimeInterval(Self.lifetime))
        guard now < staleAt else { throw .stale }
        seen = seen.filter { now < $0.value }
        guard seen[m.id] == nil else { throw .duplicate }
        guard takeSlot(m.plugin, now: now) else { throw .rateLimited }
        seen[m.id] = staleAt
        return Admitted(card: Self.card(m, manifest), key: m.group.map { .group(plugin: m.plugin, name: $0) }, staleAt: staleAt)
    }

    /// Step in an activity. Not rate-limited or deduplicated (`ActivityBoard` keeps newest by timestamp, progress updates may arrive every second); only alert consumes card quota, overflow suppresses popup while row still updates
    public mutating func admitActivity(_ m: Message, plugins: [String: Manifest], now: Date) throws(Rejection) -> ActivityUpdate {
        guard let activity = m.activity else { preconditionFailure("Regular cards go through admit") }
        let manifest = try registered(m, plugins)
        guard now < min(m.at, now).addingTimeInterval(ActivityBoard.maxAge), now < m.staleAt ?? .distantFuture else { throw .stale }
        // Future timestamp clamped to now: prevents permanent row expiration and rejecting subsequent updates/ends
        return ActivityUpdate(plugin: m.plugin, id: activity.id, event: activity.event, at: min(m.at, now), staleAt: m.staleAt,
                              alert: activity.alert && takeSlot(m.plugin, now: now), card: Self.card(m, manifest))
    }

    private func registered(_ m: Message, _ plugins: [String: Manifest]) throws(Rejection) -> Manifest {
        guard let manifest = plugins[m.plugin] else { throw .unregistered }
        return manifest
    }

    /// Check if plugin can present another card this minute; record if allowed
    private mutating func takeSlot(_ plugin: String, now: Date) -> Bool {
        let recent = (admitted[plugin] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.limit else { return false }
        admitted[plugin] = recent + [now]
        return true
    }

    private static func card(_ m: Message, _ manifest: Manifest) -> Card {
        Card(source: .plugin(id: manifest.id, name: manifest.name, symbol: manifest.symbol), title: m.title, subtitle: m.subtitle,
             value: m.value, outcome: m.outcome, block: m.block, action: m.action.map(Self.action),
             buttons: m.buttons.map { Card.Button(title: $0.title, action: Self.action($0.action)) })
    }

    private static func action(_ a: Message.Action) -> Card.Action {
        switch a {
        case .open(let url): return .open(url)
        case .activate(let id): return .activate(bundleID: id)
        case .focusTerminal(let tty, let pid, let cwd): return .terminal(TerminalRef(pid: pid, identity: .tty(tty), cwd: cwd))
        }
    }
}
