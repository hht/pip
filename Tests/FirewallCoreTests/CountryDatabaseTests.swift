import Testing
@testable import FirewallCore

/// MaxMind DB format: search tree + 16 zero bytes + data section + metadata marker + metadata.
/// @see https://maxmind.github.io/MaxMind-DB/
@Suite struct CountryNetworks {
    @Test func collectsTheCountrysNetworksAndMergesNeighbours() throws {
        let db = MMDB(ipVersion: 6)
        let cnA = db.record(country: "CN")
        let cnB = db.record(countryPointer: cnA) // Both CN, different data (GeoLite2 splits by city details), merged when adjacent
        let us = db.record(country: "US")
        db.insert("::198.51.100.0/121", cnA)
        db.insert("::198.51.100.128/121", cnB)
        db.insert("::203.0.113.0/120", us)
        db.insert("2001:db8::/32", cnA)
        // In IPv6 DB, IPv4 subtree is also mounted under ::ffff:0:0/96 (alias), traversed once and recorded as IPv4
        db.alias("::ffff:0:0/96", to: "::/96")
        #expect(try CountryDatabase.networks(country: "CN", in: db.bytes())
            == ["198.51.100.0/24", "2001:db8::/32"].map { IPNetwork($0)! })
    }

    @Test func readsAnIPv4OnlyDatabase() throws {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        db.insert("203.0.113.0/24", db.record(country: "US"))
        #expect(try CountryDatabase.networks(country: "CN", in: db.bytes()) == [IPNetwork("198.51.100.0/24")!])
    }

    /// mihomo matches country.iso_code lowercased against rule country, case-insensitive
    @Test func matchesTheCodeCaseInsensitively() throws {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        #expect(try CountryDatabase.networks(country: "cn", in: db.bytes()) == [IPNetwork("198.51.100.0/24")!])
    }

    @Test(arguments: [[UInt8](), [UInt8](repeating: 0, count: 64), Array("no marker here".utf8)])
    func rejectsWhatIsNotAnMMDB(_ bytes: [UInt8]) {
        #expect(throws: CountryDatabaseError.self) { try CountryDatabase.networks(country: "CN", in: bytes) }
    }

    /// Truncated file: tree records point outside data section, throws error without out-of-bounds access
    @Test func rejectsATruncatedDataSection() throws {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        db.truncateData = true
        #expect(throws: CountryDatabaseError.self) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// Crafted database: both child nodes of every node point to the next node. Without deduplication it would traverse 2^40 paths, hanging the enable command indefinitely
    @Test func rejectsATreeThatRevisitsANode() {
        let db = MMDB(ipVersion: 4)
        let count = 40
        db.rawTree = (count, (0..<count).flatMap { n -> [UInt8] in
            let next = n + 1 // Last points to node_count: no data
            return [0, 0, UInt8(next), 0, 0, UInt8(next)]
        })
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// Specification forbids pointers pointing to pointers; allowing it could expand into exponential decoding work
    @Test func rejectsPointersToPointers() {
        let db = MMDB(ipVersion: 4)
        let cn = db.record(country: "CN")
        let hop = db.raw([UInt8(1 << 5), UInt8(cn)])            // Pointer to cn record
        let record = db.raw([UInt8(7 << 5 | 1)] + [UInt8(2 << 5 | 7)] + Array("country".utf8) + [UInt8(1 << 5), UInt8(hop)])
        db.insert("198.51.100.0/24", record)
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// Crafted database: many leaves each point to a distinct pointer, all pointing to the same large map (without country key). Scanning it for each leaf would take O(leaves * entries), running for hours on a 9MB file. Total decoding budget is capped; exceeds budget throws error
    @Test func rejectsADatabaseThatMakesLookupsMultiply() {
        let db = MMDB(ipVersion: 4)
        let entries = 20_000
        // map, size 285 + next 2 bytes; each value is boolean false (extended type 14: control byte 0, extended byte 14 - 7)
        var big: [UInt8] = [UInt8(7 << 5 | 30), UInt8((entries - 285) >> 8), UInt8((entries - 285) & 0xFF)]
        for i in 0..<entries {
            let key = Array(String(format: "k%05d", i).utf8)
            big += [UInt8(2 << 5 | key.count)] + key + [0x00, 7]
        }
        let target = db.raw(big)
        for octet in 0..<256 {
            db.insert("\(octet).0.0.0/8", db.raw([UInt8(1 << 5 | target >> 8), UInt8(target & 0xFF)])) // Each a pointer to the large map
        }
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// Crafted database: iso_code of many records points to the same huge string, decoding it for every record. Capping header count alone is insufficient; deducting by bytes ensures total processed bytes <= file size (real DB values are only a few bytes). Keys are compared byte-by-byte without decoding strings, preventing this attack on keys
    @Test func rejectsRecordsThatAllPointAtOneHugeString() {
        let db = MMDB(ipVersion: 4)
        let size = 20_000
        let big = db.raw([UInt8(2 << 5 | 30), UInt8((size - 285) >> 8), UInt8((size - 285) & 0xFF)]
            + [UInt8](repeating: UInt8(ascii: "x"), count: size))
        for octet in 0..<60 {
            let record = db.raw([UInt8(7 << 5 | 1), UInt8(2 << 5 | 7)] + Array("country".utf8)
                + [UInt8(7 << 5 | 1), UInt8(2 << 5 | 8)] + Array("iso_code".utf8) + [UInt8(1 << 5 | big >> 8), UInt8(big & 0xFF)])
            db.insert("\(octet).0.0.0/8", record)
        }
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// Subnets have an upper bound (pf table entries are system-wide shared, capping memory and execution time): exceeding limit even after merging throws error, stopping midway
    @Test func rejectsTooManyNetworks() throws {
        let db = MMDB(ipVersion: 4)
        for third in [0, 2, 4] { db.insert("198.51.\(third).0/24", db.record(country: "CN")) } // Non-adjacent, cannot be merged
        #expect(try CountryDatabase.networks(country: "CN", in: db.bytes(), limit: 3).count == 3)
        #expect(throws: CountryDatabaseError.tooManyNetworks) { try CountryDatabase.networks(country: "CN", in: db.bytes(), limit: 2) }
    }

    /// node_count is external data: values too large for Int or overflowing multiplication throw errors rather than crashing
    @Test func rejectsAHugeNodeCount() {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        db.nodeCountOverride = [0x08, 0x02] + [UInt8](repeating: 0xFF, count: 8) // uint64 (extended type 9) maximum value
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// Two other database types recognized by mihomo (sing-geoip, Meta-geoip0) do not follow GeoLite2 record format and are unsupported here
    @Test func rejectsOtherMihomoDatabaseTypes() throws {
        let db = MMDB(ipVersion: 4)
        db.databaseType = "sing-geoip"
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        #expect(throws: CountryDatabaseError.unsupportedType("sing-geoip")) {
            try CountryDatabase.networks(country: "CN", in: db.bytes())
        }
    }
}

/// Whether allow-table domestic CIDRs resemble a plausible country: real DB (Country.mmdb included with mihomo v1.19.21 in Clash Verge Rev) covers 8.26% IPv4, shortest /10; IPv6 shortest /20
@Suite struct CountryPlausibility {
    @Test func acceptsARealisticCountry() {
        #expect(CountryDatabase.isPlausible(["1.0.1.0/24", "36.0.0.0/10", "240e::/20"].map { IPNetwork($0)! }))
    }

    /// If modified so most of the Internet is CN, production rules block nothing: single huge block or many stitched blocks are both rejected
    @Test func rejectsTooMuchOfTheInternet() {
        #expect(!CountryDatabase.isPlausible([IPNetwork("0.0.0.0/1")!]))
        #expect(!CountryDatabase.isPlausible((0..<33).map { IPNetwork("\($0).0.0.0/8")! }))
        #expect(CountryDatabase.isPlausible((0..<32).map { IPNetwork("\($0).0.0.0/8")! }))
        #expect(!CountryDatabase.isPlausible([IPNetwork("2000::/13")!]))
        // Staggered /16 subnets cannot be merged; none have short prefixes individually, but combined volume is large: computed by total volume
        #expect(!CountryDatabase.isPlausible(stride(from: 0, to: 10, by: 2).map { IPNetwork("24\(String($0, radix: 16))0::/16")! }))
        #expect(CountryDatabase.isPlausible([IPNetwork("2400::/16")!]))
        // IPv6 upper bound 2^-14: allocated IPv6 in China is ~2^-15.9 (inferred), complete databases must pass
        #expect(CountryDatabase.isPlausible(stride(from: 0, to: 6, by: 2).map { IPNetwork("24\(String($0, radix: 16))0::/16")! }))
    }
}

/// Minimal mmdb writer for tests: 24-bit records, data section only encodes maps, strings, pointers, and uints used here
private final class MMDB {
    let ipVersion: Int
    var databaseType = "GeoLite2-Country"
    var truncateData = false
    /// Directly provides search tree bytes and node count without building via insert
    var rawTree: (count: Int, bytes: [UInt8])?
    /// Encoded node_count value override in metadata
    var nodeCountOverride: [UInt8]?
    private var data: [UInt8] = []
    /// Binary tree, node 0 is root; .data stores data section offset
    private enum Child { case empty, node(Int), data(Int) }
    private var nodes: [[Child]] = [[.empty, .empty]]

    init(ipVersion: Int) { self.ipVersion = ipVersion }

    /// {"country": {"iso_code": code}}, returns data section offset
    func record(country code: String) -> Int {
        let offset = data.count
        data += map(1) + string("country")
        data += map(1) + string("iso_code") + string(code)
        return offset
    }

    /// {"continent": {"code": "AS"}, "country": <pointer to country value in other>}
    func record(countryPointer other: Int) -> Int {
        let offset = data.count
        data += map(2) + string("continent") + map(1) + string("code") + string("AS")
        data += string("country")
        let target = other + map(1).count + string("country").count
        precondition(target < 2048)
        data += [UInt8(1 << 5 | (target >> 8)), UInt8(target & 0xFF)]
        return offset
    }

    func insert(_ network: String, _ offset: Int) { set(network, .data(offset)) }

    /// Appends raw bytes to data section, returns offset
    func raw(_ bytes: [UInt8]) -> Int {
        defer { data += bytes }
        return data.count
    }

    func alias(_ network: String, to target: String) {
        guard case .node(let n) = walk(target) else { preconditionFailure("Alias must point to a node") }
        set(network, .node(n))
    }

    func bytes() -> [UInt8] {
        let count = nodes.count
        let value = { (c: Child) -> Int in
            switch c {
            case .empty: count
            case .node(let n): n
            case .data(let o): count + 16 + o
            }
        }
        var out: [UInt8] = []
        for node in nodes {
            for child in node { let v = value(child); out += [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        }
        var nodeCount = count
        if let rawTree { (nodeCount, out) = rawTree }
        out += [UInt8](repeating: 0, count: 16)
        out += truncateData ? [] : data
        out += [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        out += map(4) + string("node_count") + (nodeCountOverride ?? uint32(nodeCount)) + string("record_size") + uint16(24)
            + string("ip_version") + uint16(ipVersion) + string("database_type") + string(databaseType)
        return out
    }

    private func bits(_ network: String) -> [Int] {
        let n = IPNetwork(network)!
        precondition(n.bytes.count == (ipVersion == 4 ? 4 : 16))
        return (0..<n.prefix).map { Int(n.bytes[$0 / 8] >> (7 - UInt8($0 % 8)) & 1) }
    }

    private func set(_ network: String, _ child: Child) {
        let path = bits(network)
        var node = 0
        for bit in path.dropLast() { node = descend(node, bit) }
        nodes[node][path.last!] = child
    }

    private func walk(_ network: String) -> Child {
        let path = bits(network)
        var node = 0
        for bit in path.dropLast() { node = descend(node, bit) }
        return nodes[node][path.last!]
    }

    private func descend(_ node: Int, _ bit: Int) -> Int {
        if case .node(let n) = nodes[node][bit] { return n }
        nodes.append([.empty, .empty])
        nodes[node][bit] = .node(nodes.count - 1)
        return nodes.count - 1
    }

    private func map(_ n: Int) -> [UInt8] { [UInt8(7 << 5 | n)] }
    private func string(_ s: String) -> [UInt8] { precondition(s.utf8.count < 29); return [UInt8(2 << 5 | s.utf8.count)] + Array(s.utf8) }
    private func uint16(_ v: Int) -> [UInt8] { [UInt8(5 << 5 | 2), UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func uint32(_ v: Int) -> [UInt8] { [UInt8(6 << 5 | 4), UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
