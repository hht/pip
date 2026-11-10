import Testing
import Foundation
@testable import FirewallCore

/// Draft rules in docs/firewall.md §4, transcribed verbatim as the canonical standard for production rules; edit doc before changing rules
private let documentedRules = """
tun  = "utun1024"
lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
lan6 = "{ fe80::/10, fc00::/7 }"
mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
table <clash> file "/Library/Application Support/Notchkeeper/clash.table"
table <cn> file "/Library/Application Support/Notchkeeper/cn.table"
pass quick on lo0 no state
pass quick on $tun no state
pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
pass in  quick inet proto udp from any port 67 to any port 68
pass out quick to <clash>
block return out quick proto { tcp, udp } to any port 53
pass out quick to <cn>
pass out quick to $lan4
pass in  quick from $lan4
pass out quick to $lan6
pass in  quick from $lan6
pass out quick to { $mc4, $mc6 }
block return out quick all
block drop   in  quick all

"""

private let directory = "/Library/Application Support/Notchkeeper"

@Suite struct Rules {
    @Test func productionRulesAreTheDocumentedDraft() {
        #expect(FirewallRules(tunnel: "utun1024", directory: directory)?.text == documentedRules)
    }

    /// Interface name is interpolated directly into rules loaded as root, only accepts utun followed by digits. Physical interfaces (en0) or bridges (bridge0) are also real interfaces:
    /// If allowed, the first pass quick on $tun would allow all traffic on the physical interface while check for "TUN interface present" still passes
    @Test(arguments: ["", "utun", "1024", "utun 1024", "utun1024\"", "utun1024\nblock all", "UTUN1024", "utun1024}", "u\u{301}tun0",
                      "en0", "en1", "bridge0", "lo0", "awdl0", "xutun0", "utun1\u{301}"])
    func rejectsNonTunnelNames(_ name: String) {
        #expect(FirewallRules(tunnel: name, directory: directory) == nil)
    }

    @Test(arguments: ["utun0", "utun1024"])
    func acceptsInterfaceNames(_ name: String) {
        #expect(FirewallRules(tunnel: name, directory: directory) != nil)
    }

    /// Test rules (docs/firewall.md §7 "Tests must not disrupt network"): includes additional test table, 3 block rules modified to only block traffic to/from test table, rest verbatim matches production rules
    @Test func testRulesBlockOnlyTheTestTable() {
        let expected = documentedRules
            .replacingOccurrences(of: "tun  = \"utun1024\"", with: "tun  = \"utun9999\"")
            .replacingOccurrences(of: "table <cn> file \"\(directory)/cn.table\"\n",
                                  with: "table <cn> file \"\(directory)/cn.table\"\ntable <test> file \"\(directory)/test.table\"\n")
            .replacingOccurrences(of: "block return out quick proto { tcp, udp } to any port 53\n",
                                  with: "block return out quick proto { tcp, udp } to <test> port 53\n")
            .replacingOccurrences(of: "block return out quick all\n", with: "block return out quick to <test>\n")
            .replacingOccurrences(of: "block drop   in  quick all\n", with: "block drop   in  quick from <test>\n")
        #expect(expected != documentedRules)
        #expect(FirewallRules(tunnel: "utun9999", scope: .testTable, directory: directory)?.text == expected)
    }

    /// user / group cause kernel deadlock in pf requiring reboot (docs/firewall.md §5): must never appear in any rules
    @Test(arguments: [FirewallRules.Scope.everyone, .testTable])
    func rulesNeverMatchOnUserOrGroup(_ scope: FirewallRules.Scope) throws {
        let words = try #require(FirewallRules(tunnel: "utun1024", scope: scope, directory: directory)).text
            .split(whereSeparator: { $0.isWhitespace || $0 == "{" || $0 == "}" || $0 == "," })
        #expect(!words.contains("user"))
        #expect(!words.contains("group"))
    }

    /// System pfctl validates parsing without loading (-n does not need root) to catch syntax errors; whether it catches bad rules is proven by second test case.
    /// -n still reads table files, so written into temporary directory
    @Test(arguments: [FirewallRules.Scope.everyone, .testTable])
    func pfctlParsesTheRules(_ scope: FirewallRules.Scope) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, line) in [("clash", "198.51.100.1"), ("cn", "198.51.100.0/28"), ("test", "198.51.100.9")] {
            try Data("\(line)\n".utf8).write(to: dir.appendingPathComponent("\(name).table"))
        }
        #expect(try pfctlParses(#require(FirewallRules(tunnel: "utun1024", scope: scope, directory: dir.path)).text))
        #expect(try !pfctlParses("block bogus\n"))
    }
}

private func pfctlParses(_ rules: String) throws -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
    p.arguments = ["-nf", "-"]
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    input.fileHandleForWriting.write(Data(rules.utf8))
    try input.fileHandleForWriting.close()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
