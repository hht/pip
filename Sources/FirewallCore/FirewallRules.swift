/// Answers: what rules are loaded into this anchor. Modeled after Mullvad's macOS pf rules; differences and rationale documented in docs/firewall.md §4.
/// Unaware of how rules are loaded into pf, whether loading succeeded, or table contents.
/// @see https://github.com/mullvad/mullvadvpn-app/blob/33a63e2916adf294d3b4332c4274e2aa1cb1f811/talpid-core/src/firewall/macos.rs
public struct FirewallRules: Equatable, Sendable {
    /// Full text piped into `pfctl -a <anchor> -f -`
    public let text: String

    /// Targets of block rules
    public enum Scope: String, Codable, Sendable {
        /// Production rules: blocks all traffic except tunnel, LAN, and the two allow tables
        case everyone
        /// Test rules: block only targets traffic to/from test table `<test>`, leaving normal traffic unaffected during tests (docs/firewall.md §7)
        case testTable
    }

    /// File names of the two allow tables and test table (under `directory`); also referenced in rescue and install scripts, sync if modified
    public static let clashTableFile = "clash.table", cnTableFile = "cn.table", testTableFile = "test.table"

    /// `tunnel` is Clash's TUN interface name. Interpolated directly into rules loaded as root; only accepts `utun` followed by digits (macOS TUN interfaces are named utunN), returns `nil` otherwise.
    /// Setting to a real physical interface (e.g. en0) would cause the first `pass quick on $tun` to pass all traffic on it while checks still pass, so verifying interface name prefix alone is insufficient.
    /// `directory` is the directory containing table files (root 0755, docs/firewall.md §4).
    /// Neither rule variant specifies `user` / `group`: they trigger kernel deadlocks in pf requiring reboot (§5).
    public init?(tunnel: String, scope: Scope = .everyone, directory: String) {
        // Compare by Unicode scalar: Character comparison treats '1' followed by combining characters as numeric
        let digits = tunnel.unicodeScalars.dropFirst(4)
        guard tunnel.hasPrefix("utun"), !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        // Directory is a hardcoded constant passed by caller; containing quotes or newlines indicates programmer error
        guard !directory.contains(where: { $0 == "\"" || $0.isNewline }) else { preconditionFailure("Table directory must not contain quotes or newlines") }
        let test = scope == .testTable
        let table = { (name: String, file: String) in "table <\(name)> file \"\(directory)/\(file)\"\n" }
        text = """
        tun  = "\(tunnel)"
        lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
        mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
        lan6 = "{ fe80::/10, fc00::/7 }"
        mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
        \(table("clash", Self.clashTableFile))\(table("cn", Self.cnTableFile))\(test ? table("test", Self.testTableFile) : "")pass quick on lo0 no state
        pass quick on $tun no state
        pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
        pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
        pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
        pass in  quick inet proto udp from any port 67 to any port 68
        pass out quick to <clash>
        block return out quick proto { tcp, udp } to \(test ? "<test>" : "any") port 53
        pass out quick to <cn>
        pass out quick to $lan4
        pass in  quick from $lan4
        pass out quick to $lan6
        pass in  quick from $lan6
        pass out quick to { $mc4, $mc6 }
        block return out quick \(test ? "to <test>" : "all")
        block drop   in  quick \(test ? "from <test>" : "all")

        """
    }
}
