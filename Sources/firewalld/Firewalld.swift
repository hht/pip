import Darwin
import Foundation
import FirewallCore

/// Answers: what firewall helper program does given arguments (docs/firewall.md §4 "Privileged Helper").
///
/// - `notchkeeper-firewall round --tunnel <interface> [--test-rules]`: LaunchDaemon, every 10s during trial / on, exits upon returning to off.
///   `--test-rules` loads test rules (block only intercepts traffic to test table, without actually cutting off internet, §7)
/// - `notchkeeper-firewall enable --clash <clash-dir> | keep | disable`: invoked by App via osascript with administrator privileges
/// - `notchkeeper-firewall rules --tunnel <interface> [--test-rules]`: prints rules that a round would load, used by install script for inspection and syntax check
///
/// Except for printing rules, requires root: non-root users do nothing.
@main
enum Firewalld {
    static let usage = "Usage: notchkeeper-firewall round|rules --tunnel <interface> [--test-rules] | enable --clash <clash-dir> | keep | disable"

    /// What the invocation specifies
    enum Invocation: Equatable {
        case round(Helper.RoundConfig)
        case rules(Helper.RoundConfig)
        case command(Helper.Command)
    }

    static func main() {
        // Prevent SIGPIPE when writing to stdin of child processes that exit early; daemon exiting prematurely leaves round incomplete
        signal(SIGPIPE, SIG_IGN)
        guard let invocation = parse(Array(CommandLine.arguments.dropFirst())) else { fail(usage, code: 64) }
        let requireRoot = { if geteuid() != 0 { fail("Must run as root", code: 1) } }
        switch invocation {
        case .rules(let config):
            print(config.rules.text, terminator: "")
        case .round(let config):
            requireRoot()
            Helper.serve(.live, config) { sleep(10) }
        case .command(let command):
            requireRoot()
            do {
                if let tables = try Helper.command(command, .live) {
                    print("Trial enabled (auto-disables if not kept within 2 minutes). Allow tables: <clash> \(tables.clash.count) entries, <cn> \(tables.cn.count) subnets")
                }
            } catch {
                fail(message(error), code: 1)
            }
        }
    }

    /// `round|rules --tunnel <interface> [--test-rules]`, `enable --clash <path>`, `keep`, `disable`: strictly matching argument count
    static func parse(_ args: [String]) -> Invocation? {
        switch (args.first, args.count) {
        case ("keep", 1): return .command(.keep)
        case ("disable", 1): return .command(.disable)
        case ("enable", 3) where args[1] == "--clash" && args[2].hasPrefix("/"):
            return .command(.enable(clash: URL(fileURLWithPath: args[2])))
        case ("round", _): return roundConfig(Array(args.dropFirst())).map(Invocation.round)
        case ("rules", _): return roundConfig(Array(args.dropFirst())).map(Invocation.rules)
        default: return nil
        }
    }

    private static func roundConfig(_ args: [String]) -> Helper.RoundConfig? {
        switch args.count {
        case 2 where args[0] == "--tunnel":
            Helper.RoundConfig(tunnel: args[1], scope: .everyone)
        case 3 where args[0] == "--tunnel" && args[2] == "--test-rules":
            Helper.RoundConfig(tunnel: args[1], scope: .testTable)
        default:
            nil
        }
    }

    private static func message(_ failure: Helper.Failure) -> String {
        switch failure {
        case .command(.notOff): "Firewall is already enabled"
        case .command(.notInTrial): "Not in trial (may have expired and rolled back); nothing to keep"
        case .command(.bootSessionUnknown): "Cannot read boot session ID (kern.bootsessionuuid); cannot determine if rebooted, cannot enable or keep"
        case .stateUnreadable: "Firewall state file is unreadable; run sudo scripts/firewall-rescue.sh before reinstalling"
        case .snapshot(let f): "Failed to enable: " + snapshotMessage(f)
        case .busy: "Another operation is in progress, please try again later"
        case .io(let m): m
        }
    }

    private static func snapshotMessage(_ failure: SnapshotFailure) -> String {
        switch failure {
        case .unreadable(let name): "Cannot read \(name) in Clash Verge directory"
        case .config(.proxyProviders): "Clash config contains proxy-providers; node addresses are not in config file"
        case .config(.noNodes): "Clash config contains no nodes"
        case .config(.unsupported(let line)): "Unrecognized syntax at line \(line) of Clash config"
        case .database(.malformed): "Country.mmdb is not a valid GeoIP database"
        case .database(.unsupportedType(let type)): "Unsupported GeoIP database type: \(type)"
        case .noCountryNetworks: "Country.mmdb contains no domestic (CN) IP ranges"
        case .implausibleCountryNetwork: "Country.mmdb contains an implausibly large domestic subnet; database may have been tampered with"
        case .table(.tooManyNodes): "Domain nodes in Clash config exceed \(ClashRuntimeConfig.maxDomainNodes); does not look like a genuine subscription"
        case .database(.tooManyNetworks), .table(.tooManyEntries): "Allow table exceeds \(CountryDatabase.maxTableEntries) entries; pf cannot load"
        case .table(.noResolver): "proxy-server-nameserver in Clash config has no direct plaintext UDP upstream; cannot resolve node addresses"
        case .table(.unresolved(let node)): "Address for node \(node) could not be resolved (is Clash running?)"
        case .table(.fakeAnswer(let node)): "Resolved address for node \(node) is a fake-ip, not a real address"
        case .table(.notADomain(let node)): "Server for node \(node) does not look like a domain name"
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        fputs("notchkeeper-firewall: \(message)\n", stderr)
        exit(code)
    }
}
