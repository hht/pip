import Foundation
import FirewallCore
@testable import firewalld

/// Fake pf: responds to pfctl, ifconfig, launchctl according to actual observed machine output (docs/firewall.md §6),
/// recording every invocation
final class FakePF: @unchecked Sendable {
    var anchor = ""
    var references: [String] = []
    var nextToken = 1_864_012_227_745_836_441 as UInt64
    var evaluations: UInt64 = 0
    var mainRules = "scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all\n"
    var interfaces = "lo0 en0 utun1024\n"
    var calls: [[String]] = []
    var enabled = true
    /// `false`: References does not list our acquired token (simulating -E token not matching list)
    var listsOurReferences = true
    /// Make command fail: invocation whose arguments contain this substring returns 1
    var failing: String?
    /// Inspection hook before each invocation (used to test "persisting immediately after token acquisition")
    var onCall: ([String]) -> Void = { _ in }
    /// Answers when dig queries A records against 127.0.0.1:7874; unlisted names have no answer
    var dns: [String: [String]] = ["node.example": ["198.51.100.1"]]

    func run(_ executable: String, _ arguments: [String], _ input: String?) -> Output {
        let call = [executable] + arguments
        onCall(call)
        calls.append(call)
        if let failing, call.contains(failing) { return Output(status: 1, stdout: "", stderr: "pfctl: failed\n") }
        let noise = "No ALTQ support in kernel\nALTQ related functions disabled\n"
        switch call {
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-sr"]:
            return Output(status: 0, stdout: anchor, stderr: noise)
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-vsr"]:
            evaluations += 100
            let rules = anchor.split(separator: "\n").map { "\($0)\n  [ Evaluations: \(evaluations)  Packets: 0 ]\n" }.joined()
            return Output(status: 0, stdout: rules, stderr: noise)
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-f", "-"]:
            anchor = input ?? ""
            return Output(status: 0, stdout: "", stderr: noise)
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-F", "rules"]:
            anchor = ""
            return Output(status: 0, stdout: "", stderr: noise + "rules cleared\n")
        case ["/sbin/pfctl", "-E"]:
            enabled = true
            let token = String(nextToken)
            nextToken += 1
            references.append(token)
            return Output(status: 0, stdout: "", stderr: noise + "pf enabled\nToken : \(token)\n")
        case ["/sbin/pfctl", "-sr"]:
            return Output(status: 0, stdout: mainRules, stderr: noise)
        case ["/sbin/pfctl", "-s", "References"]:
            let rows = (["12184426722627826779"] + (listsOurReferences ? references : [])).map { "49256    pfd                          \($0)     0 days 00:00:12\n" }
            return Output(status: 0, stdout: "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n" + rows.joined(),
                          stderr: noise)
        case ["/sbin/pfctl", "-s", "info"]:
            return Output(status: 0, stdout: enabled ? "Status: Enabled for 0 days 00:00:12           Debug: Urgent\n" : "Status: Disabled\n",
                          stderr: noise)
        case ["/sbin/ifconfig", "-l"]:
            return Output(status: 0, stdout: interfaces, stderr: "")
        case ["/bin/launchctl", "kickstart", "-k", "system/\(FirewallPaths.label)"]:
            return Output(status: 0, stdout: "", stderr: "")
        default:
            if call.count == 11, call[0] == "/usr/bin/dig", Array(call[1...6]) == ["+short", "+time=2", "+tries=1", "-p", "7874", "@127.0.0.1"],
               call[7] == "-t", call[9] == "-q" {
                let answers = call[8] == "A" ? dns[call[10]] ?? [] : []
                return Output(status: 0, stdout: answers.map { "\($0)\n" }.joined(), stderr: "")
            }
            if call.count == 3, call[0] == "/sbin/pfctl", call[1] == "-X", let i = references.firstIndex(of: call[2]) {
                references.remove(at: i)
                return Output(status: 0, stdout: "", stderr: noise + "disable request successful.\n")
            }
            return Output(status: 1, stdout: "", stderr: "unexpected call\n")
        }
    }
}

/// Temporary directory + fake pf + manually controlled clock
final class Rig: @unchecked Sendable {
    let pf = FakePF()
    let directory: URL
    var seconds: Int64 = 100
    var bootSession: String? = "B5E97D3E-1F68-4627-B43C-2257F22F12DB"
    var lockTimeout: TimeInterval = 30
    var system: FirewallSystem {
        FirewallSystem(directory: directory,
                       moment: { Moment(bootSession: self.bootSession, now: MonotonicTime(milliseconds: self.seconds * 1000)) },
                       now: { Date(timeIntervalSince1970: 1_793_419_500 + TimeInterval(self.seconds)) },
                       run: { self.pf.run($0, $1, $2) }, lockTimeout: lockTimeout)
    }
    let rules = FirewallRules(tunnel: "utun1024", directory: FirewallPaths.directory.path)!

    /// Fake Clash Verge directory: 1 domain node, 1 IP upstream; domestic subnet is 0.0.0.0/8
    let clash: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("firewalld-tests-\(UUID().uuidString)")
        clash = directory.appendingPathComponent("clash-verge-rev")
        try FileManager.default.createDirectory(at: clash, withIntermediateDirectories: true)
        try Data("""
        dns:
          nameserver:
          - 198.51.100.53
          proxy-server-nameserver:
          - udp://127.0.0.1:7874
          fake-ip-range: 198.18.0.1/16
        proxies:
        - name: A
          server: node.example
          port: 10015

        """.utf8).write(to: clash.appendingPathComponent("clash-verge.yaml"))
        try Data(Self.countryDatabase(prefix: 8)).write(to: clash.appendingPathComponent("Country.mmdb"))
    }

    func enable() throws(Helper.Failure) { _ = try Helper.command(.enable(clash: clash), system) }

    func table(_ name: String) -> String? {
        (try? Data(contentsOf: directory.appendingPathComponent("\(name).table"))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// IPv4 mmdb: 0.0.0.0/`prefix` is CN, no data elsewhere (see CountryDatabaseTests in FirewallCoreTests for format).
    /// A left-chain of `prefix` nodes; left child of last node points to data offset 0, remaining right children are "no data" (= node_count)
    static func countryDatabase(prefix: Int) -> [UInt8] {
        let string = { (s: String) in [UInt8(2 << 5 | s.utf8.count)] + Array(s.utf8) }
        let map = { (n: Int) in [UInt8(7 << 5 | n)] }
        let uint16 = { (v: UInt8) in [UInt8(5 << 5 | 1), v] }
        let tree = (0..<prefix).flatMap { n -> [UInt8] in
            let left = n == prefix - 1 ? prefix + 16 : n + 1
            return [0, 0, UInt8(left), 0, 0, UInt8(prefix)]
        }
        let data = map(1) + string("country") + map(1) + string("iso_code") + string("CN")
        let metadata = map(4) + string("node_count") + uint16(UInt8(prefix)) + string("record_size") + uint16(24)
            + string("ip_version") + uint16(4) + string("database_type") + string("GeoLite2-Country")
        return tree + [UInt8](repeating: 0, count: 16) + data + [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8) + metadata
    }

    func round(scope: FirewallRules.Scope = .everyone) -> FirewallStatus? {
        Helper.round(system, Helper.RoundConfig(tunnel: "utun1024", scope: scope)!)
    }

    var state: FirewallState.Restored {
        FirewallState.restore(from: try? Data(contentsOf: directory.appendingPathComponent(FirewallState.fileName)))
    }

    var status: FirewallStatus? {
        (try? Data(contentsOf: directory.appendingPathComponent(FirewallStatus.fileName))).flatMap { try? FirewallStatus.decode($0) }
    }
}
