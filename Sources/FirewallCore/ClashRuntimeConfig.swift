import Foundation

/// Answers: in Clash Verge's runtime config (`clash-verge.yaml` loaded by mihomo with `-f`), which addresses will mihomo connect to directly, and whom should node domains be queried against.
/// Reads only these fields; other fields (including passwords) are strictly ignored and not retained; unaware of file locations or domain resolution details (docs/firewall.md §4 "Snapshot allow tables on enable").
///
/// Not a general-purpose YAML parser: Clash Verge produces block YAML where lists share indentation with parent keys, top-level keys are flush left, and keys under `dns` are indented by 2 spaces.
/// Rejects keys formatted differently (single-line `[...]`, `{...}`) rather than assuming absence, preferring failure over silent omission.
public struct ClashRuntimeConfig: Equatable, Sendable {
    /// Node `server` entries, deduplicated preserving order of appearance: IP or domain
    public var servers: [String]
    /// Upstream resolvers used by mihomo for node domains: plain UDP IP addresses in `proxy-server-nameserver`
    public var nodeResolvers: [DNSServer]
    /// DNS upstreams directly connected by mihomo formatted as IPs (domains excluded). Does not read `nameserver-policy`: omissions only affect querying those domains, without leaking traffic.
    public var upstreamAddresses: [IPNetwork]
    /// Resolved IPs falling into this range are fake-ip, not real addresses
    public var fakeIPRange: IPNetwork

    /// Maximum allowed domain nodes. Real subscriptions range from dozens to hundreds; each requires two DNS queries on startup.
    public static let maxDomainNodes = 2000

    /// Used when mihomo does not specify `fake-ip-range`. @see https://wiki.metacubex.one/config/dns/#fake-ip-range
    static let defaultFakeIPRange = IPNetwork("198.18.0.1/16")!
    /// DNS upstream list directly connected by mihomo. @see https://wiki.metacubex.one/config/dns/
    private static let upstreamKeys: Set<Substring> = ["default-nameserver", "nameserver", "fallback", "proxy-server-nameserver", "direct-nameserver"]

    public init(yaml: String) throws(ClashConfigError) {
        // Deduplicate using Set: external file could have many nodes, Array.contains is quadratic
        var servers: [String] = [], seenServers: Set<String> = []
        var resolvers: [DNSServer] = []
        var upstreams: [IPNetwork] = [], seenUpstreams: Set<IPNetwork> = []
        var fakeIPRange: IPNetwork?
        var providers = false
        var section: Substring?
        var dnsKey: Substring?
        // Split by isNewline: Swift treats "\r\n" as a single character, splitting on "\n" fails for CRLF files
        for (index, line) in yaml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let unsupported = ClashConfigError.unsupported(line: index + 1)
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if body.isEmpty || body.first == "#" { continue }
            let item = body.hasPrefix("- ")

            if indent == 0, !item {
                guard let (key, value) = Self.keyValue(body) else { throw unsupported }
                (section, dnsKey) = (key, nil)
                switch key {
                case "proxy-providers": if !value.isEmpty, value != "{}" { throw unsupported }
                case "proxies", "dns": if !value.isEmpty { throw unsupported }
                default: break
                }
                continue
            }
            switch section {
            case "proxy-providers":
                providers = true
            case "proxies":
                // Each node is a map starting with `- `, fields indented 2 spaces further than `- `; deeper levels like plugin-opts do not represent node servers.
                // List items in fields (indented 2 spaces with `- `) only include servers in WireGuard peers. Reject nodes written as single lines where server cannot be extracted.
                if indent == 0, item, body.dropFirst(2).first == "{" { throw unsupported }
                let (field, level) = (indent == 0 || indent == 2) && item ? (body.dropFirst(2), 2) : (body, indent)
                guard level == 2, let (key, value) = Self.keyValue(field), key == "server" else { continue }
                guard let server = Self.scalar(value), !server.isEmpty else { throw unsupported }
                if seenServers.insert(server).inserted { servers.append(server) }
            case "dns" where indent == 2 && !item:
                guard let (key, value) = Self.keyValue(body) else { throw unsupported }
                dnsKey = key
                if key == "fake-ip-range" {
                    guard let range = Self.scalar(value).flatMap(IPNetwork.init) else { throw unsupported }
                    fakeIPRange = range
                } else if Self.upstreamKeys.contains(key), !value.isEmpty {
                    throw unsupported
                }
            case "dns" where indent > 2 && item:
                // Upstream list indented deeper than key: only recognizes same indentation level as key; reject unrecognized formatting to avoid missing upstreams.
                if let key = dnsKey, Self.upstreamKeys.contains(key) { throw unsupported }
            case "dns" where indent == 2 && item:
                guard let key = dnsKey, Self.upstreamKeys.contains(key) else { continue }
                guard let entry = Self.scalar(body.dropFirst(2)) else { throw unsupported }
                let upstream = DNSUpstream(entry)
                if let address = upstream.address, seenUpstreams.insert(address).inserted { upstreams.append(address) }
                if key == "proxy-server-nameserver", let server = upstream.plainUDP { resolvers.append(server) }
            default:
                continue
            }
        }
        guard !providers else { throw .proxyProviders }
        guard !servers.isEmpty else { throw .noNodes }
        self.servers = servers
        nodeResolvers = resolvers
        upstreamAddresses = upstreams
        self.fakeIPRange = fakeIPRange ?? Self.defaultFakeIPRange
    }

    /// `key: value` or `key:`; unquoted keys (all target keys are unquoted)
    private static func keyValue(_ s: Substring) -> (Substring, Substring)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let rest = s[s.index(after: colon)...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (s[..<colon], rest.drop { $0 == " " })
    }

    /// Single quotes, unescaped double quotes, bare values (stripping comments starting with ` #`); returns `nil` if unrecognized.
    private static func scalar(_ s: Substring) -> String? {
        let v = s.drop { $0 == " " }
        if v.first == "'" {
            guard v.count >= 2, v.last == "'" else { return nil }
            return v.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        if v.first == "\"" {
            guard v.count >= 2, v.last == "\"", !v.contains("\\") else { return nil }
            return String(v.dropFirst().dropLast())
        }
        let plain = v.range(of: " #").map { v[..<$0.lowerBound] } ?? v
        return String(plain.reversed().drop { $0 == " " }.reversed())
    }
}

public enum ClashConfigError: Error, Equatable {
    /// Subscription not expanded in file (`proxy-providers`), node addresses unavailable
    case proxyProviders
    case noNodes
    /// Line formatted in an unrecognized way; does not report content to avoid leaking secrets into logs
    case unsupported(line: Int)
}

/// A plain UDP DNS server
public struct DNSServer: Equatable, Sendable {
    public var address: IPNetwork
    public var port: Int
    public init(address: IPNetwork, port: Int) { (self.address, self.port) = (address, port) }
}

/// A DNS upstream in mihomo: `223.5.5.5`, `198.51.100.53:5353`, `udp://...`, `tls://...`, `https://[2001:db8::53]/dns-query`, or with `#...` parameters
/// @see https://wiki.metacubex.one/config/dns/
struct DNSUpstream {
    /// Host formatted as IP; `nil` if domain (or `system`, `dhcp://...`)
    let address: IPNetwork?
    /// Server when using plain UDP (omitted scheme or `udp://`)
    let plainUDP: DNSServer?

    init(_ entry: String) {
        var rest = Substring(entry.prefix { $0 != "#" })
        var scheme: Substring = "udp"
        if let r = rest.range(of: "://") {
            scheme = rest[..<r.lowerBound]
            rest = rest[r.upperBound...]
        }
        let authority = rest.prefix { $0 != "/" }
        var host = authority
        var port: Int? = 53
        if authority.first == "[" {
            // [v6] or [v6]:port
            guard let close = authority.firstIndex(of: "]") else { (address, plainUDP) = (nil, nil); return }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let tail = authority[authority.index(after: close)...]
            if !tail.isEmpty { port = tail.first == ":" ? Int(tail.dropFirst()) : nil }
        } else if authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") {
            // v4:port; bare IPv6 without brackets has multiple colons
            host = authority[..<colon]
            port = Int(authority[authority.index(after: colon)...])
        }
        let ip = IPNetwork(String(host)).flatMap { $0.prefix == $0.bytes.count * 8 ? $0 : nil }
        address = ip
        if let ip, let port, scheme == "udp" { plainUDP = DNSServer(address: ip, port: port) } else { plainUDP = nil }
    }
}

extension ClashRuntimeConfig {
    /// `<clash>` table: node addresses (domain names queried against `nodeResolvers` in order using `resolve` until resolved) plus DNS upstreams written as IPs, deduplicated in order of appearance.
    /// Fails if any node cannot be resolved or resolves to a fake-ip: missing nodes in allow table would prevent Clash from connecting while firewall is active.
    /// `resolve` returning `nil` indicates upstream timeout: does not re-query it for subsequent nodes to avoid waiting through timeout repeatedly. Fails if exceeding `limit`: pf cannot hold them.
    public func clashTable(limit: Int = CountryDatabase.maxTableEntries, resolve: (String, DNSServer) -> [IPNetwork]?) throws(AllowTableError) -> [IPNetwork] {
        guard servers.count(where: { IPNetwork($0) == nil }) <= Self.maxDomainNodes else { throw .tooManyNodes }
        var table: [IPNetwork] = [], seen: Set<IPNetwork> = []
        func add(_ n: IPNetwork) throws(AllowTableError) {
            guard seen.insert(n).inserted else { return }
            guard table.count < limit else { throw .tooManyEntries }
            table.append(n)
        }
        var silent: Set<Int> = []
        for (index, server) in servers.enumerated() {
            let node = index + 1
            if let ip = IPNetwork(server), ip.prefix == ip.bytes.count * 8 {
                try add(ip)
                continue
            }
            guard Self.isDomain(server) else { throw .notADomain(node: node) }
            guard !nodeResolvers.isEmpty else { throw .noResolver }
            var answers: [IPNetwork] = []
            for (i, resolver) in nodeResolvers.enumerated() where answers.isEmpty && !silent.contains(i) {
                if let a = resolve(server, resolver) { answers = a } else { silent.insert(i) }
            }
            guard !answers.isEmpty else { throw .unresolved(node: node) }
            guard !answers.contains(where: fakeIPRange.contains) else { throw .fakeAnswer(node: node) }
            for a in answers { try add(a) }
        }
        for a in upstreamAddresses { try add(a) }
        return table
    }

    /// Letters, digits, `-`, `_`, `.`, starting with letter or digit. Passed directly to dig run as root; `-` or `+` at start would be parsed as flags.
    static func isDomain(_ s: String) -> Bool {
        let alphanumeric = { (c: Unicode.Scalar) in c.isASCII && CharacterSet.alphanumerics.contains(c) }
        guard let first = s.unicodeScalars.first, alphanumeric(first) else { return false }
        return s.unicodeScalars.allSatisfy { alphanumeric($0) || "-_.".unicodeScalars.contains($0) }
    }
}

/// Failure to snapshot `<clash>` table; reports node 1-based index in config, without exposing domain or address.
public enum AllowTableError: Error, Equatable {
    /// Too many domain nodes to resemble a realistic subscription: each requires 2 DNS queries, slowing startup and risking overflowing pf table.
    case tooManyNodes
    /// Entries exceed allocated capacity: pf cannot hold them.
    case tooManyEntries
    /// Node is a domain name, but config lacks plain UDP upstreams (`proxy-server-nameserver`) to query directly.
    case noResolver
    case unresolved(node: Int)
    case fakeAnswer(node: Int)
    case notADomain(node: Int)
}
