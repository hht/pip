import Foundation
import Testing
import NotchCore
@testable import PluginCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let source = Card.Source.plugin(id: "dl", name: "Download", symbol: "arrow.down.circle")

private func update(_ event: Message.Activity.Event = .update, id: String = "xcode", plugin: String = "dl", sent: TimeInterval = 0,
                    title: String = "Downloading", value: String? = nil, outcome: Card.Outcome = .info, block: Card.Block? = nil,
                    alert: Bool = false, staleAt: Date? = nil) -> ActivityUpdate {
    ActivityUpdate(plugin: plugin, id: id, event: event, at: at(sent), staleAt: staleAt, alert: alert,
                   card: Card(source: .plugin(id: plugin, name: "Download", symbol: "arrow.down.circle"), title: title, value: value,
                              outcome: outcome, block: block))
}

/// Activities occupy a row in plugin panel section (following ActivityKit): start / update refreshes in place, end removes; newest by timestamp
@Suite struct ActivityRows {
    @Test func startAddsRow() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        #expect(board.rows(for: "dl") == [PanelRow(id: "dl:xcode", icon: .symbol("arrow.down.circle"), title: "Downloading", indicator: .working,
                                                   trailing: .since(at(1)))])
    }

    @Test func updateRefreshesInPlaceAndKeepsStart() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        _ = board.apply(update(sent: 5, title: "Almost done", value: "1 min left"), now: at(5))
        let rows = board.rows(for: "dl")
        #expect(rows.count == 1 && rows[0].title == "Almost done" && rows[0].trailing == .value("1 min left"))
    }

    /// Out-of-order older messages do not overwrite newer ones
    @Test func olderIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(sent: 5, title: "New"), now: at(5))
        #expect(board.apply(update(sent: 4, title: "Old"), now: at(6)) == nil)
        #expect(board.apply(update(sent: 5, title: "Same time"), now: at(6)) == nil)
        #expect(board.rows(for: "dl").map(\.title) == ["New"])
    }

    /// Updates without seeing start (App started late, start expired) admitted: update treated as start
    @Test func updateWithoutStartCreates() {
        var board = ActivityBoard()
        _ = board.apply(update(sent: 3), now: at(3))
        #expect(board.rows(for: "dl").first?.trailing == .since(at(3)))
    }

    @Test func endRemovesAndLaterOldUpdateIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        #expect(board.apply(update(.end, sent: 9), now: at(9)) != nil)
        #expect(board.rows(for: "dl").isEmpty)
        #expect(board.apply(update(sent: 8), now: at(10)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
        // Subsequent new activity with same name treated as new
        _ = board.apply(update(.start, sent: 20), now: at(20))
        #expect(board.rows(for: "dl").count == 1)
    }

    @Test func indicators() {
        var board = ActivityBoard()
        _ = board.apply(update(id: "a", block: .progress(0.4, label: nil)), now: t0)
        _ = board.apply(update(id: "b", sent: 1, outcome: .attention), now: at(1))
        #expect(board.rows(for: "dl").map(\.indicator) == [.progress(0.4), .attention])
    }

    /// Sorted by start time, updates do not reorder rows (consistent session row)
    @Test func orderedByStart() {
        var board = ActivityBoard()
        _ = board.apply(update(id: "a", sent: 1), now: at(1))
        _ = board.apply(update(id: "b", sent: 2), now: at(2))
        _ = board.apply(update(id: "a", sent: 3, title: "a2"), now: at(3))
        #expect(board.rows(for: "dl").map(\.id) == ["dl:a", "dl:b"])
    }

    /// Max 5 per plugin: evict longest un-updated
    @Test func capPerPlugin() {
        var board = ActivityBoard()
        for i in 0..<6 { _ = board.apply(update(id: "a\(i)", sent: Double(i)), now: at(Double(i))) }
        _ = board.apply(update(id: "x", plugin: "other", sent: 6), now: at(6))
        #expect(board.rows(for: "dl").map(\.id) == (1..<6).map { "dl:a\($0)" })
        #expect(board.rows(for: "other").count == 1)
    }

    @Test func removePlugin() {
        var board = ActivityBoard()
        _ = board.apply(update(), now: t0)
        board.remove(plugin: "dl")
        #expect(board.rows(for: "dl").isEmpty)
    }
}

/// Plugin urgency is highest urgency among active activities; calm if no activities
@Suite struct ActivityUrgencies {
    @Test func urgencies() {
        var board = ActivityBoard()
        #expect(board.urgency(for: "dl") == .calm)
        _ = board.apply(update(id: "a"), now: t0)
        #expect(board.urgency(for: "dl") == .active)
        _ = board.apply(update(id: "b", sent: 1, outcome: .attention), now: at(1))
        #expect(board.urgency(for: "dl") == .attention)
    }
}

/// Activities max 8 hours (following ActivityKit), or when staleAt reached; expired rows removed. App calls `expire` on `deadline`
@Suite struct ActivityExpiry {
    @Test func expiresAtStaleAtOrMaxAge() {
        var board = ActivityBoard()
        _ = board.apply(update(id: "a", staleAt: at(60)), now: t0)
        _ = board.apply(update(id: "b", sent: 1), now: at(1))
        #expect(board.deadline == at(60))
        board.expire(now: at(59))
        #expect(board.rows(for: "dl").count == 2)
        board.expire(now: at(60))
        #expect(board.rows(for: "dl").map(\.id) == ["dl:b"])
        #expect(board.deadline == at(1 + 8 * 3600))
    }

    /// Updates do not extend lifetime: 8 hours counted from start (following ActivityKit)
    @Test func updatesDoNotExtendMaxAge() {
        var board = ActivityBoard()
        _ = board.apply(update(.start), now: t0)
        _ = board.apply(update(sent: 3600), now: at(3600))
        #expect(board.deadline == at(8 * 3600))
    }
}

/// Presenting cards: delivered to App on alert; card id remains stable across updates, App updates in-place
@Suite struct ActivityCards {
    @Test func cardKeepsIDAcrossUpdates() {
        var board = ActivityBoard()
        let a = board.apply(update(.start, alert: true), now: t0)
        let b = board.apply(update(sent: 1, title: "Almost done"), now: at(1))
        #expect(a?.alert == true && b?.alert == false)
        #expect(a?.card.id == b?.card.id && b?.card.title == "Almost done")
        #expect(a?.key == .activity(plugin: "dl", id: "xcode"))
    }

    /// End card also reuses id: queued or presenting card transitions to final state
    @Test func endCardKeepsID() {
        var board = ActivityBoard()
        let a = board.apply(update(.start, alert: true), now: t0)
        let end = board.apply(update(.end, sent: 1, title: "Downloaded", outcome: .done, alert: true), now: at(1))
        #expect(end?.card.id == a?.card.id && end?.card.outcome == .done && end?.alert == true)
    }
}

/// When timestamps match, follows step order: start < update < end. If script ends within 1s of start, row is removed; duplicate messages at same instant still ignored
@Suite struct ActivitySameInstant {
    @Test func endInSameInstantRemoves() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        _ = board.apply(update(sent: 1, title: "Almost done"), now: at(1))
        #expect(board.rows(for: "dl").first?.title == "Almost done")
        #expect(board.apply(update(.end, sent: 1), now: at(1)) != nil)
        #expect(board.rows(for: "dl").isEmpty)
    }

    @Test func startAfterEndInSameInstantIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.end, sent: 1), now: at(1))
        #expect(board.apply(update(.start, sent: 1), now: at(1)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
    }

    /// Activities started at the same instant sorted by id, deterministic order
    @Test func sameStartOrderedByID() {
        var board = ActivityBoard()
        for id in ["c", "a", "b"] { _ = board.apply(update(id: id, sent: 1), now: at(1)) }
        #expect(board.rows(for: "dl").map(\.id) == ["dl:a", "dl:b", "dl:c"])
    }
}

/// Newly arrived activity older than 5 active ones evicted immediately: no card presented (and no row in panel)
@Suite struct ActivityDroppedOnArrival {
    @Test func noCardWhenSelfDropped() {
        var board = ActivityBoard()
        for i in 0..<5 { _ = board.apply(update(id: "a\(i)", sent: Double(10 + i)), now: at(20)) }
        #expect(board.apply(update(id: "old", sent: 1, alert: true), now: at(20)) == nil)
        #expect(!board.rows(for: "dl").contains { $0.id == "dl:old" })
    }

    /// Card expiration follows row: expires at staleAt if specified
    @Test func cardCarriesStaleAt() {
        var board = ActivityBoard()
        #expect(board.apply(update(alert: true, staleAt: at(30)), now: t0)?.staleAt == at(30))
    }
}

/// Ended activities (end, 8 hours or staleAt reached, evicted) reject updates, only a new start can reopen (following ActivityKit)
@Suite struct EndedActivity {
    @Test func updateAfterEndIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        _ = board.apply(update(.end, sent: 2), now: at(2))
        #expect(board.apply(update(sent: 3), now: at(3)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
    }

    @Test func updateAfterMaxAgeIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.start), now: t0)
        board.expire(now: at(8 * 3600))
        #expect(board.apply(update(sent: 8 * 3600 + 60), now: at(8 * 3600 + 60)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
        _ = board.apply(update(.start, sent: 8 * 3600 + 120), now: at(8 * 3600 + 120))
        #expect(board.rows(for: "dl").count == 1)
    }

    @Test func updateAfterDroppedIgnored() {
        var board = ActivityBoard()
        for i in 0..<6 { _ = board.apply(update(id: "a\(i)", sent: Double(i)), now: at(Double(i))) }
        #expect(board.apply(update(id: "a0", sent: 10), now: at(10)) == nil)
    }
}
