import Foundation
import Testing
import FirewallCore
@testable import firewalld

/// Snapshot allow tables on enable (docs/firewall.md §4): only enable reads user directory; daemon only loads two table files from root directory
@Suite struct Snapshot {
    @Test func enableWritesBothAllowTables() throws {
        let rig = try Rig()
        try rig.enable()
        #expect(rig.table("clash") == "198.51.100.1/32\n198.51.100.53/32\n127.0.0.1/32\n")
        #expect(rig.table("cn") == "0.0.0.0/8\n")
        let mode = try FileManager.default.attributesOfItem(atPath: rig.directory.appendingPathComponent("cn.table").path)[.posixPermissions]
        #expect(mode as? Int == 0o644)
        // Node domain queries mihomo's node DNS upstream for both A and AAAA records
        #expect(rig.pf.calls.filter { $0.first == "/usr/bin/dig" }.map { $0[8] } == ["A", "AAAA"])
    }

    /// Enable returns both tables; CLI uses this to print counts for user verification (detects tampered mmdb)
    @Test func enableReturnsTheTables() throws {
        let rig = try Rig()
        let tables = try Helper.command(.enable(clash: rig.clash), rig.system)
        #expect(tables?.clash.count == 3)
        #expect(tables?.cn.count == 1)
    }

    /// Database contains zero CN subnets (format changed): refuse to enable, otherwise all DIRECT traffic blocked under production rules
    @Test func enableRefusesAnEmptyCountryTable() throws {
        let rig = try Rig()
        var mmdb = Rig.countryDatabase(prefix: 8)
        let cn = Array("CN".utf8)
        let at = try #require(mmdb.indices.first { mmdb[$0] == cn[0] && mmdb[$0 + 1] == cn[1] })
        mmdb.replaceSubrange(at...(at + 1), with: Array("US".utf8))
        try Data(mmdb).write(to: rig.clash.appendingPathComponent("Country.mmdb"))
        #expect(throws: Helper.Failure.snapshot(.noCountryNetworks)) { try rig.enable() }
    }

    /// Database tampered so most of the internet is CN: refuse to enable, otherwise production rules block nothing while verification passes (see `CountryDatabase.isPlausible`)
    @Test func enableRefusesImplausiblyWideCountryNetworks() throws {
        let rig = try Rig()
        try Data(Rig.countryDatabase(prefix: 1)).write(to: rig.clash.appendingPathComponent("Country.mmdb"))
        #expect(throws: Helper.Failure.snapshot(.implausibleCountryNetwork)) { try rig.enable() }
    }

    /// Answer is fake-ip: refuse to enable, state untouched, tables not written
    @Test func enableRefusesFakeIPAnswers() throws {
        let rig = try Rig()
        rig.pf.dns["node.example"] = ["198.18.0.3"]
        #expect(throws: Helper.Failure.snapshot(.table(.fakeAnswer(node: 1)))) { try rig.enable() }
        #expect(rig.state == .missing)
        #expect(rig.table("clash") == nil)
        #expect(!rig.pf.calls.contains { $0.first == "/bin/launchctl" })
    }

    @Test func enableRefusesUnreadableClashFiles() throws {
        let rig = try Rig()
        try FileManager.default.removeItem(at: rig.clash.appendingPathComponent("Country.mmdb"))
        #expect(throws: Helper.Failure.snapshot(.unreadable("Country.mmdb"))) { try rig.enable() }
        #expect(rig.state == .missing)
    }

    /// root reading user-writable directory: refuses symlinks (could point to root-only files or /dev/zero) and FIFOs (hangs on read)
    @Test func enableRefusesLinksAndPipes() throws {
        let rig = try Rig()
        let mmdb = rig.clash.appendingPathComponent("Country.mmdb")
        try FileManager.default.removeItem(at: mmdb)
        try FileManager.default.createSymbolicLink(at: mmdb, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: Helper.Failure.snapshot(.unreadable("Country.mmdb"))) { try rig.enable() }
        try FileManager.default.removeItem(at: mmdb)
        #expect(mkfifo(mmdb.path, 0o600) == 0)
        #expect(throws: Helper.Failure.snapshot(.unreadable("Country.mmdb"))) { try rig.enable() }
    }

    /// Re-enabling while already on: reports already enabled, currently active tables untouched
    @Test func enableWhileOnLeavesTheTablesAlone() throws {
        let rig = try Rig()
        try rig.enable()
        try Helper.command(.keep, rig.system)
        rig.pf.dns["node.example"] = ["198.51.100.9"]
        #expect(throws: Helper.Failure.command(.notOff)) { try rig.enable() }
        #expect(rig.table("clash")?.hasPrefix("198.51.100.1/32\n") == true)
    }
}

/// Daemon: round after round during trial / on, exits after completing the round that returns to off (docs/firewall.md §2)
@Suite struct Serve {
    private let config = Helper.RoundConfig(tunnel: "utun1024", scope: .everyone)!

    @Test func keepsGoingWhileOnAndStopsAfterTheRoundThatTurnsOff() throws {
        let rig = try Rig()
        try rig.enable()
        var pauses = 0
        Helper.serve(rig.system, config) {
            pauses += 1
            rig.seconds += 10
            if pauses == 3 { _ = try? Helper.command(.disable, rig.system) }
        }
        #expect(pauses == 3)
        #expect(rig.pf.anchor == "")
        #expect(rig.status?.mode == .off)
    }

    /// The round where trial expires returns to off, and process exits accordingly; expiration rollback relies solely on this
    @Test func stopsWhenTheTrialExpires() throws {
        let rig = try Rig()
        try rig.enable()
        var pauses = 0
        Helper.serve(rig.system, config) {
            pauses += 1
            rig.seconds += 30
        }
        #expect(pauses == 4) // 30, 60, 90s still in trial; expires in round at 120s
        #expect(rig.pf.anchor == "")
    }

    /// If rule flush fails in round returning to off: do not exit, retry next round, exit only once cleaned up.
    /// Nobody else cleans up after exit, leaving host-wide block rule hanging.
    @Test func keepsGoingUntilOffIsCleanedUp() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-F"
        var pauses = 0
        Helper.serve(rig.system, config) {
            pauses += 1
            if pauses == 2 { rig.pf.failing = nil }
        }
        #expect(pauses == 2)
        #expect(rig.pf.anchor == "")
        #expect(rig.pf.references.isEmpty)
    }

    /// Returning to off where only release fails: exits normally. An extra reference does not break internet, running every 10s for it would constitute polling while off
    @Test func stopsEvenIfOnlyTheReleaseFails() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-X"
        Helper.serve(rig.system, config) { Issue.record("Only release failed, should not wait for next round") }
        #expect(rig.pf.anchor == "")
    }

    @Test func offRunsOneRoundAndStops() throws {
        let rig = try Rig()
        rig.pf.anchor = "pass all\n"
        Helper.serve(rig.system, config) { Issue.record("Should not wait for next round when off") }
        #expect(rig.pf.anchor == "")
    }
}
