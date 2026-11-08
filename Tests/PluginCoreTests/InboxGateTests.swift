import Foundation
import Testing
import NotchCore
@testable import PluginCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private let terminal = Manifest(id: "terminal", name: "Terminal", symbol: "terminal")
private let plugins = ["terminal": terminal]

private func message(plugin: String = "terminal", id: UUID = UUID(), sent: Date = t0, group: String? = nil, staleAt: Date? = nil) -> Message {
    Message(plugin: plugin, id: id, at: sent, group: group, title: "npm finished", subtitle: "~/x", value: "12s", outcome: .failed,
            block: .facts([.init(title: "Exit code", value: "1")]), action: .activate(bundleID: "com.mitchellh.ghostty"),
            buttons: [.init(title: "Read docs", action: .open(URL(string: "https://example.com")!))], staleAt: staleAt)
}

@Suite struct ManifestParsing {
    private func parse(_ json: String, in directory: String = "terminal") throws -> Manifest {
        try Manifest.parse(Data(json.utf8), directoryName: directory)
    }

    @Test func parses() throws {
        #expect(try parse(#"{"id":"terminal","name":"Terminal","symbol":"terminal","future":1}"#) == terminal)
    }

    /// Directory name is plugin id: reject mismatches to prevent impersonation
    @Test func idMustMatchDirectory() {
        #expect(throws: ManifestError.badID) { try parse(#"{"id":"guard","name":"Terminal","symbol":"terminal"}"#) }
    }

    /// Directory name matches, but not a valid plugin id
    @Test func badIDRejected() {
        #expect(throws: ManifestError.badID) { try parse(#"{"id":"Terminal","name":"Terminal","symbol":"terminal"}"#, in: "Terminal") }
    }

    @Test(arguments: [#"{"id":"terminal","name":" ","symbol":"terminal"}"#, #"{"id":"terminal","name":"Terminal","symbol":""}"#])
    func blankFieldsRejected(_ json: String) {
        #expect(throws: ManifestError.missingField) { try parse(json) }
    }

    @Test(arguments: ["{", #"{"id":"terminal","name":"Terminal"}"#])
    func malformedRejected(_ json: String) {
        #expect(throws: ManifestError.malformed) { try parse(json) }
    }

    /// Name fits at most `Card.maxValue` characters on card: reject on install to avoid truncation
    @Test(arguments: [#"{"id":"terminal","name":"\#(String(repeating: "a", count: 25))","symbol":"terminal"}"#,
                      #"{"id":"terminal","name":"Terminal","symbol":"\#(String(repeating: "a", count: 65))"}"#])
    func tooLongRejectedAtInstall(_ json: String) {
        #expect(throws: ManifestError.tooLong) { try Manifest.parse(Data(json.utf8), directoryName: nil) }
    }

    /// Already installed plugins (manifest modified to be longer after install) still receive cards: name truncated by card, mismatched icon replaced by App
    @Test func tooLongStillRegistered() throws {
        let name = String(repeating: "a", count: 25)
        #expect(try parse(#"{"id":"terminal","name":"\#(name)","symbol":"terminal"}"#).name == name)
    }

    @Test func longestAccepted() throws {
        let name = String(repeating: "a", count: Card.maxValue)
        #expect(try Manifest.parse(Data(#"{"id":"terminal","name":"\#(name)","symbol":"terminal"}"#.utf8), directoryName: nil).name == name)
    }
}

/// Inbox and registrations are written externally: arbitrary bytes only fail parsing, never crash App (Principle 5)
@Suite struct ParsingNeverTraps {
    /// Fixed seed: reproducible failures (Principle 4)
    @Test func randomBytes() {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<2000 {
            let data = Data((0..<Int.random(in: 0...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? Message.parse(data)
            _ = try? Manifest.parse(data, directoryName: nil)
        }
    }

    /// Every prefix of valid message, plus byte-mutated variants
    @Test func mutatedValidMessages() {
        let valid = Data(#"{"v":1,"plugin":"ci","id":"8D3B7C1E-2F4A-4B6C-9D8E-1A2B3C4D5E6F","at":"2026-10-31T00:00:00Z","title":"x","outcome":"done","block":{"type":"progress","value":1e308},"buttons":[{"type":"Action.OpenUrl","title":"a","url":"https://a.com"}],"activity":{"id":"a","event":"start"}}"#.utf8)
        for i in valid.indices {
            _ = try? Message.parse(valid.prefix(i))
            for byte: UInt8 in [0, 0x22, 0x5C, 0x7B, 0x7D, 0xFF] {
                var bad = valid
                bad[i] = byte
                _ = try? Message.parse(bad)
            }
        }
    }
}

@Suite struct InboxAdmission {
    @Test func registeredMessageBecomesCard() throws {
        var gate = InboxGate()
        let admitted = try gate.admit(message(group: "tty1"), plugins: plugins, now: t0)
        let card = admitted.card
        #expect(card.source == .plugin(id: "terminal", name: "Terminal", symbol: "terminal"))
        #expect(card.title == "npm finished" && card.subtitle == "~/x" && card.value == "12s" && card.outcome == .failed)
        #expect(card.block == .facts([.init(title: "Exit code", value: "1")]))
        #expect(card.action == .activate(bundleID: "com.mitchellh.ghostty"))
        #expect(card.buttons == [.init(title: "Read docs", action: .open(URL(string: "https://example.com")!))])
        #expect(admitted.key == .group(plugin: "terminal", name: "tty1"))
    }

    /// Shell lacks process start time: identified by "tty for pid is still this"
    @Test func focusTerminalBecomesTerminalAction() throws {
        var gate = InboxGate()
        var m = message()
        m.action = .focusTerminal(tty: "/dev/ttys003", pid: 4242, cwd: "/Users/x")
        m.buttons = []
        let card = try gate.admit(m, plugins: plugins, now: t0).card
        #expect(card.action == .terminal(TerminalRef(pid: 4242, identity: .tty("/dev/ttys003"), cwd: "/Users/x")))
    }

    @Test func ungroupedHasNoKey() throws {
        var gate = InboxGate()
        #expect(try gate.admit(message(), plugins: plugins, now: t0).key == nil)
    }

    /// Discard messages from unregistered plugins (CLAUDE.md hard rule "Plugins")
    @Test func unregisteredDropped() {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.unregistered) { try gate.admit(message(plugin: "build"), plugins: plugins, now: t0) }
    }

    @Test func staleAtPassedDropped() throws {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.stale) { try gate.admit(message(staleAt: at(10)), plugins: plugins, now: at(10)) }
        _ = try gate.admit(message(staleAt: at(10)), plugins: plugins, now: at(9))
    }

    /// No staleAt specified: dropped 10 minutes after sending (accumulated while App closed)
    @Test func oldMessageDropped() throws {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.stale) { try gate.admit(message(), plugins: plugins, now: at(600)) }
        _ = try gate.admit(message(), plugins: plugins, now: at(599))
    }

    /// Expiration passed to queue: without staleAt, 10 min after sent; staleAt can only be earlier, not later;
    /// Future sent timestamp clamped to received time, prevents perpetual retention
    @Test(arguments: [(nil as TimeInterval?, 0.0, 600.0), (30, 0, 30), (3600, 0, 600), (nil, 86400, 600), (nil, -100, 500)])
    func staleAtHandedToQueue(_ staleAt: TimeInterval?, _ sent: TimeInterval, _ expected: TimeInterval) throws {
        var gate = InboxGate()
        let admitted = try gate.admit(message(sent: at(sent), staleAt: staleAt.map(at)), plugins: plugins, now: t0)
        #expect(admitted.staleAt == at(expected))
    }

    /// Same id admitted only once: script resending same message does not present twice
    @Test func sameIDOnce() throws {
        var gate = InboxGate()
        let id = UUID()
        _ = try gate.admit(message(id: id), plugins: plugins, now: t0)
        #expect(throws: InboxGate.Rejection.duplicate) { try gate.admit(message(id: id), plugins: plugins, now: at(1)) }
    }

    /// Deduplication only tracks until message expires: subsequent message with same id (and updated sent time) treated as new
    @Test func sameIDAfterExpiryIsNew() throws {
        var gate = InboxGate()
        let id = UUID()
        _ = try gate.admit(message(id: id), plugins: plugins, now: t0)
        _ = try gate.admit(message(id: id, sent: at(600)), plugins: plugins, now: at(600))
    }

    /// At most 6 messages per minute per plugin, excess dropped; other plugins unaffected, recovers after 1 minute
    @Test func rateLimitedPerPlugin() throws {
        var gate = InboxGate()
        let both = plugins.merging(["build": Manifest(id: "build", name: "Build", symbol: "hammer")]) { a, _ in a }
        for i in 0..<6 { _ = try gate.admit(message(sent: at(Double(i))), plugins: both, now: at(Double(i))) }
        #expect(throws: InboxGate.Rejection.rateLimited) { try gate.admit(message(sent: at(30)), plugins: both, now: at(30)) }
        _ = try gate.admit(message(plugin: "build", sent: at(30)), plugins: both, now: at(30))
        _ = try gate.admit(message(sent: at(60)), plugins: both, now: at(60))
        #expect(throws: InboxGate.Rejection.rateLimited) { try gate.admit(message(sent: at(60.5)), plugins: both, now: at(60.5)) }
    }

    /// Rejected messages do not consume rate limit slots
    @Test func rejectedDoNotCount() throws {
        var gate = InboxGate()
        for _ in 0..<10 { _ = try? gate.admit(message(staleAt: t0), plugins: plugins, now: t0) }
        for _ in 0..<6 { _ = try gate.admit(message(), plugins: plugins, now: t0) }
    }
}

/// Reserved built-in plugin IDs: settings switches stored by id, prevents collision with external plugins
@Suite struct ReservedPluginIDs {
    @Test(arguments: ["guard", "claude"])
    func builtInIDsRejected(_ id: String) {
        #expect(throws: ManifestError.reservedID) {
            try Manifest.parse(Data(#"{"id":"\#(id)","name":"x","symbol":"star"}"#.utf8), directoryName: id)
        }
    }
}

private func activity(_ event: Message.Activity.Event = .update, alert: Bool = false, sent: Date = t0, staleAt: Date? = nil) -> Message {
    var m = message(sent: sent, staleAt: staleAt)
    m.activity = .init(id: "xcode", event: event, alert: alert)
    return m
}

/// Activity messages do not pop card (unless alert) and bypass rate limit; only alert consumes quota, overflow suppresses popup while row updates
@Suite struct ActivityAdmission {
    @Test func becomesUpdate() throws {
        var gate = InboxGate()
        let u = try gate.admitActivity(activity(.start), plugins: plugins, now: t0)
        #expect(u.plugin == "terminal" && u.id == "xcode" && u.event == .start && u.at == t0 && !u.alert)
        #expect(u.card.title == "npm finished" && u.card.source == .plugin(id: "terminal", name: "Terminal", symbol: "terminal"))
    }

    @Test func updatesAreNotRateLimited() throws {
        var gate = InboxGate()
        for i in 0..<20 { _ = try gate.admitActivity(activity(sent: at(Double(i))), plugins: plugins, now: at(Double(i))) }
        _ = try gate.admit(message(sent: at(20)), plugins: plugins, now: at(20))
    }

    @Test func alertOverLimitStillUpdatesRow() throws {
        var gate = InboxGate()
        for _ in 0..<6 { _ = try gate.admit(message(), plugins: plugins, now: t0) }
        let u = try gate.admitActivity(activity(alert: true), plugins: plugins, now: t0)
        #expect(!u.alert)
    }

    @Test func alertCountsAgainstLimit() throws {
        var gate = InboxGate()
        for _ in 0..<6 {
            let u = try gate.admitActivity(activity(alert: true), plugins: plugins, now: t0)
            #expect(u.alert)
        }
        #expect(throws: InboxGate.Rejection.rateLimited) { try gate.admit(message(), plugins: plugins, now: t0) }
    }

    /// Activities max 8 hours (following ActivityKit): older not admitted; staleAt passed also dropped
    @Test func staleActivityDropped() throws {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.stale) { try gate.admitActivity(activity(), plugins: plugins, now: at(8 * 3600)) }
        _ = try gate.admitActivity(activity(), plugins: plugins, now: at(8 * 3600 - 1))
        #expect(throws: InboxGate.Rejection.stale) { try gate.admitActivity(activity(staleAt: at(5)), plugins: plugins, now: at(5)) }
    }

    @Test func unregisteredDropped() {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.unregistered) { try gate.admitActivity(activity(), plugins: [:], now: t0) }
    }
}

/// Future sent time clamped to now: prevents perpetual retention and treating future updates/ends as old
@Suite struct FutureActivity {
    @Test func futureAtClampedToNow() throws {
        var gate = InboxGate()
        var m = message(sent: at(86400))
        m.activity = .init(id: "x", event: .start, alert: false)
        #expect(try gate.admitActivity(m, plugins: plugins, now: t0).at == t0)
    }
}

/// Deterministic PRNG for tests
/// @see https://prng.di.unimi.it/splitmix64.c
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
