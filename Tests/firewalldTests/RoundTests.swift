import Foundation
import Testing
import FirewallCore
@testable import firewalld

@Suite struct Round {
    @Test func enableThenRoundLoadsRulesAndHoldsOneReference() throws {
        let rig = try Rig()
        try rig.enable()
        let status = try #require(rig.round())
        #expect(rig.pf.anchor == rig.rules.text)
        #expect(rig.pf.references == ["1864012227745836441"])
        guard case .valid(let s) = rig.state else { Issue.record("Cannot read firewall state file"); return }
        #expect(s.reference == .held(token: "1864012227745836441"))
        #expect(status.mode == .trial)
        #expect(status.check?.passed == true)
        #expect(rig.status == status)
    }

    /// Steady state neither calls -E nor reloads: reference count does not grow, Evaluations not reset
    @Test func steadyRoundsNeitherReEnableNorReload() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        rig.seconds += 10
        let status = try #require(rig.round())
        #expect(rig.pf.references.count == 1)
        #expect(rig.pf.calls.filter { $0.contains("-f") }.count == 1)
        #expect(status.check?.evaluationsGrowing == true)
    }

    /// Persist to disk as soon as token is acquired: state file already contains it before the next step after -E (re-reading reference list).
    /// If rescue script bootout terminates exactly at this point, it can find this token to release
    @Test func tokenIsOnDiskBeforeTheNextStep() throws {
        let rig = try Rig()
        try rig.enable()
        var next: [String]?
        var seen: FirewallState.Restored?
        rig.pf.onCall = { call in
            if next == nil, rig.pf.calls.last == ["/sbin/pfctl", "-E"] { (next, seen) = (call, rig.state) }
        }
        _ = rig.round()
        #expect(next == ["/sbin/pfctl", "-s", "References"])
        guard case .valid(let s) = seen else { Issue.record("Cannot read firewall state file on next step"); return }
        #expect(s.reference == .held(token: "1864012227745836441"))
    }

    /// State file corrupt: treated as off (cleans leftover rules), does not overwrite original file, reported in summary
    @Test func unreadableStateIsTreatedAsOffAndKept() throws {
        let rig = try Rig()
        let url = rig.directory.appendingPathComponent(FirewallState.fileName)
        try Data("garbage".utf8).write(to: url)
        rig.pf.anchor = "pass all\n"
        let status = try #require(rig.round())
        #expect(rig.pf.anchor == "")
        #expect(try Data(contentsOf: url) == Data("garbage".utf8))
        #expect(status.mode == .stateUnreadable)
    }

    /// Failed action reported in summary, retried next round
    @Test func failedActionIsReportedAndRetried() throws {
        let rig = try Rig()
        try rig.enable()
        rig.pf.failing = "-E"
        #expect(rig.round()?.failedSteps == [.enable])
        #expect(rig.pf.references.isEmpty)
        rig.pf.failing = nil
        rig.seconds += 10
        #expect(rig.round()?.failedSteps == [])
        #expect(rig.pf.references.count == 1)
    }

    @Test func disableFlushesAndReleases() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        let status = try #require(rig.round())
        #expect(rig.pf.anchor == "")
        #expect(rig.pf.references.isEmpty)
        #expect(status.mode == .off)
        #expect(status.check == nil)
    }

    /// Expiration rollback executed by a round, independent of App; clicking keep after expiration is refused
    @Test func expiredTrialRollsBackAndCannotBeKept() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        rig.seconds += 120
        #expect(throws: Helper.Failure.command(.notInTrial)) { try Helper.command(.keep, rig.system) }
        let status = try #require(rig.round())
        #expect(status.mode == .off)
        #expect(rig.pf.anchor == "")
        #expect(rig.pf.references.isEmpty)
    }

    @Test func trialShowsWhenItEnds() throws {
        let rig = try Rig()
        try rig.enable()
        rig.seconds += 30
        #expect(rig.round()?.trialEndsAt == rig.system.now().addingTimeInterval(90))
    }

    /// Commands do not touch pf; they modify files only, then restart daemon to run an immediate round
    @Test(arguments: [Helper.Command.keep, .disable])
    func commandsRestartTheDaemon(_ command: Helper.Command) throws {
        let rig = try Rig()
        try rig.enable()
        #expect(rig.pf.calls.last == ["/bin/launchctl", "kickstart", "-k", "system/com.notchkeeper.firewall"])
        #expect(!rig.pf.calls.contains { $0.first == "/sbin/pfctl" })
        rig.pf.calls = []
        _ = try? Helper.command(command, rig.system)
        #expect(rig.pf.calls == [["/bin/launchctl", "kickstart", "-k", "system/com.notchkeeper.firewall"]])
    }

    /// Firewall state file is readable only by root (contains tokens); summary readable by App
    @Test func filePermissions() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        func mode(_ name: String) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: rig.directory.appendingPathComponent(name).path)[.posixPermissions] as? Int
        }
        #expect(try mode(FirewallState.fileName) == 0o600)
        #expect(try mode(FirewallStatus.fileName) == 0o644)
    }

    /// Someone runs pfctl -d: references invalidated, pf stopped. Next round detects our token is gone, re-enables with -E, verification passes again
    @Test func recoversAfterSomeoneDisablesPF() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        rig.pf.references = []
        rig.pf.enabled = false
        rig.seconds += 10
        let status = try #require(rig.round())
        #expect(rig.pf.references.count == 1)
        #expect(status.check?.pfEnabled == true)
    }

    /// -E token not found in reference list (format mismatch): acquires only one reference, not accumulating every round
    @Test func unlistedTokenIsNotReEnabledEveryRound() throws {
        let rig = try Rig()
        rig.pf.listsOurReferences = false
        try rig.enable()
        _ = rig.round()
        rig.seconds += 10
        _ = rig.round()
        #expect(rig.pf.references.count == 1)
    }

    /// Flush fails in disable round, re-enabled while daemon is still running: reload freshly snapshotted tables,
    /// cannot keep old tables just because "rule text unchanged, anchor not empty"
    @Test func enableAfterAFailedFlushReloads() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-F"
        _ = rig.round()
        rig.pf.failing = nil
        try rig.enable()
        _ = rig.round()
        #expect(rig.pf.calls.filter { $0.contains("-f") }.count == 2)
    }

    /// Lock is held (another round or command stuck): gives up when limit reached, modifies nothing
    @Test func givesUpWhenTheLockIsHeld() throws {
        let rig = try Rig()
        rig.lockTimeout = 0.2
        let fd = open(rig.directory.appendingPathComponent(FirewallPaths.lockFile).path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(throws: Helper.Failure.busy) { try rig.enable() }
        #expect(rig.round() == nil)
        #expect(rig.state == .missing)
        #expect(rig.table("clash") == nil)
        #expect(rig.pf.calls.allSatisfy { $0.first == "/usr/bin/dig" }) // Snapshot DNS queries are outside lock, not counted as modification
    }

    /// Corrupted state file overwritten by neither: enable rejected (run rescue script first); disable still succeeds (each round treats unreadable as off anyway)
    @Test func commandsDoNotOverwriteAnUnreadableState() throws {
        let rig = try Rig()
        let url = rig.directory.appendingPathComponent(FirewallState.fileName)
        try Data("garbage".utf8).write(to: url)
        #expect(throws: Helper.Failure.stateUnreadable) { try rig.enable() }
        try Helper.command(.disable, rig.system)
        #expect(try Data(contentsOf: url) == Data("garbage".utf8))
    }

    @Test func releaseFailureIsRetried() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-X"
        #expect(rig.round()?.failedSteps == [.release])
        rig.pf.failing = nil
        #expect(rig.round()?.failedSteps == [])
        #expect(rig.pf.references.isEmpty)
    }

    /// Summary states which rules are loaded: test rules cannot cause App to display "protected"
    @Test func statusSaysWhichRules() throws {
        let rig = try Rig()
        try rig.enable()
        #expect(rig.round(scope: .testTable)?.scope == .testTable)
        #expect(rig.pf.anchor == FirewallRules(tunnel: "utun1024", scope: .testTable, directory: FirewallPaths.directory.path)?.text)
    }

    /// Boot session unreadable: enable errors with descriptive reason; rounds proceed as off, state file omits boot session
    @Test func unreadableBootSession() throws {
        let rig = try Rig()
        rig.bootSession = nil
        #expect(throws: Helper.Failure.command(.bootSessionUnknown)) { try rig.enable() }
        rig.pf.anchor = "pass all\n"
        #expect(rig.round()?.mode == .off)
        #expect(rig.pf.anchor == "")
        guard case .valid(let s) = rig.state else { Issue.record("Cannot read firewall state file"); return }
        #expect(s.bootSession == nil)
    }

    /// Rule replacement fails in round: anchor retains old rules, summary must not claim new rules
    @Test func statusHasNoScopeWhenTheseRulesAreNotLoaded() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round(scope: .testTable)
        rig.pf.failing = "-f"
        rig.seconds += 10
        #expect(rig.round(scope: .everyone)?.scope == nil)
    }

    /// Does not enable via -E if state cannot be saved: acquired token cannot be recorded, repeating -E every round with unbounded token growth
    @Test func doesNotEnableWhenStateCannotBeSaved() throws {
        let rig = try Rig()
        try rig.enable()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.directory.path) }
        #expect(rig.round()?.failedSteps == [.enable])
        #expect(rig.pf.references.isEmpty)
    }
}

@Suite struct Arguments {
    @Test func round() {
        #expect(Firewalld.parse(["round", "--tunnel", "utun1024"]) == .round(Helper.RoundConfig(tunnel: "utun1024", scope: .everyone)!))
        #expect(Firewalld.parse(["round", "--tunnel", "utun1024", "--test-rules"])
            == .round(Helper.RoundConfig(tunnel: "utun1024", scope: .testTable)!))
    }

    /// Print rules is an independent command: the only one not requiring root
    @Test func rules() {
        #expect(Firewalld.parse(["rules", "--tunnel", "utun9999", "--test-rules"])
            == .rules(Helper.RoundConfig(tunnel: "utun9999", scope: .testTable)!))
    }

    @Test func commands() {
        #expect(Firewalld.parse(["enable", "--clash", "/Users/someone/Clash"]) == .command(.enable(clash: URL(fileURLWithPath: "/Users/someone/Clash"))))
        #expect(Firewalld.parse(["keep"]) == .command(.keep))
        #expect(Firewalld.parse(["disable"]) == .command(.disable))
    }

    @Test(arguments: [[], ["round"], ["rules"], ["round", "--tunnel"], ["round", "--tunnel", "utun 1"],
                      ["round", "--tunnel", "utun1024", "--extra"], ["round", "--tunnel", "utun1024", "--test-rules", "x"],
                      ["--tunnel", "utun1024", "round"], ["enable", "x"], ["enable"], ["enable", "--clash"], ["enable", "--clash", "relative/dir"], ["--tunnel", "utun1024"], ["status"]])
    func rejects(_ args: [String]) {
        #expect(Firewalld.parse(args) == nil)
    }
}
