/// Answers: which IP networks belong to a specific country in mihomo's GEOIP database (`Country.mmdb`).
/// Follows mihomo's method for matching `GEOIP,CN`: for GeoLite2 databases,
/// the record's `country.iso_code` lowercased matches the country in the rule. Adjacent networks in the same country are merged.
/// Only recognizes GeoLite2 record format; location of file is external. Out-of-bounds or invalid formats throw errors, never crashing.
/// @see https://maxmind.github.io/MaxMind-DB/
/// @see https://github.com/MetaCubeX/mihomo/blob/Meta/component/mmdb/reader.go
public enum CountryDatabase {
    /// Maximum combined entries for both allow tables. pf table entries are system-wide shared (XNU default limit ~200k, inferred). Real DB domestic CIDRs count 8928, keeping an order of magnitude margin.
    public static let maxTableEntries = 100_000

    /// Throws an error if merged networks exceed `limit`: stops midway, capping both memory and execution time.
    public static func networks(country: String, in bytes: [UInt8], limit: Int = maxTableEntries) throws(CountryDatabaseError) -> [IPNetwork] {
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        guard let markerStart = lastIndex(of: marker, in: bytes) else { throw .malformed }
        let metadata = Decoder(bytes: bytes, base: markerStart + marker.count, end: bytes.count)
        let field = { (key: String) throws(CountryDatabaseError) -> Int? in try metadata.field(key, inMapAt: 0) }
        // External data: compare against file size before multiplying to avoid overflow
        guard let nodeCount = try metadata.uint(at: field("node_count")), let recordSize = try metadata.uint(at: field("record_size")),
              let ipVersion = try metadata.uint(at: field("ip_version")), [24, 28, 32].contains(recordSize), [4, 6].contains(ipVersion),
              nodeCount <= UInt64(bytes.count)
        else { throw .malformed }
        if let type = try metadata.string(at: field("database_type")), ["sing-geoip", "Meta-geoip0"].contains(type) {
            throw .unsupportedType(type)
        }
        let treeSize = Int(recordSize) * 2 / 8 * Int(nodeCount)
        guard treeSize + 16 <= markerStart else { throw .malformed }
        let walker = Walker(bytes: bytes, nodeCount: Int(nodeCount), recordSize: Int(recordSize),
                            data: Decoder(bytes: bytes, base: treeSize + 16, end: markerStart), country: country.lowercased(),
                            limit: limit)
        return try walker.networks(ipVersion: Int(ipVersion))
    }

    /// Checks whether domestic allow-table CIDRs resemble a plausible country: total coverage must not exceed 1/8 of IPv4 space and 2^-14 of IPv6 space.
    /// Computed by total volume: staggered small blocks cannot be merged, prefix-only checks cannot guard against this.
    /// In the real DB (Country.mmdb included with mihomo v1.19.21 in Clash Verge Rev), IPv4 covers 8.26%, IPv6 ~2^-17.4; allocated IPv6 in China is ~2^-15.9 (inferred), so complete databases must pass.
    /// If a database were tampered with to classify most of the Internet as CN, formal rules would block nothing while checks would pass.
    public static func isPlausible(_ networks: [IPNetwork]) -> Bool {
        // Double summation will not overflow (crafted DBs could have many CIDRs); integer powers of 2 are exact in Double
        let share = { (family: Int) in
            networks.filter { $0.bytes.count == family }.reduce(0.0) { $0 + Double(sign: .plus, exponent: -$1.prefix, significand: 1) }
        }
        return share(4) <= 0x1p-3 && share(16) <= 0x1p-14
    }

    private static func lastIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        return stride(from: bytes.count - needle.count, through: 0, by: -1).first { i in
            needle.indices.allSatisfy { bytes[i + $0] == needle[$0] }
        }
    }
}

public enum CountryDatabaseError: Error, Equatable {
    /// Not an mmdb, or truncated / out of bounds
    case malformed
    /// mihomo recognized, but unsupported type here
    case unsupportedType(String)
    /// Domestic networks exceed upper limit: pf cannot hold them
    case tooManyNetworks
}

/// Traverses the search tree
private final class Walker {
    let bytes: [UInt8]
    let nodeCount: Int
    let recordSize: Int
    let data: Decoder
    let country: String
    let limit: Int
    /// Data section offset -> whether it matches this country; GeoLite2 shares records across many subnets
    var verdicts: [Int: Bool] = [:]
    /// Root of IPv4 subtree in IPv6 DB (`::/96`); other references to it are aliases (`::ffff:0:0/96`, `2002::/16`), traversed only once
    var ipv4Root: Int?
    /// Visited nodes. In a valid tree apart from aliases above, every node has only one parent; revisiting indicates a cyclic/crafted DB (which would take 2^depth without guarding)
    var visited: [Bool]

    init(bytes: [UInt8], nodeCount: Int, recordSize: Int, data: Decoder, country: String, limit: Int) {
        (self.bytes, self.nodeCount, self.recordSize, self.data, self.country, self.limit) = (bytes, nodeCount, recordSize, data, country, limit)
        visited = [Bool](repeating: false, count: nodeCount)
    }

    func networks(ipVersion: Int) throws(CountryDatabaseError) -> [IPNetwork] {
        guard ipVersion == 6 else { return try walk(0, path: [UInt8](repeating: 0, count: 4), depth: 0).networks }
        var node = 0
        for _ in 0..<96 {
            guard node < nodeCount else { break }
            node = try record(node, 0)
        }
        if node < nodeCount { ipv4Root = node }
        return try walk(0, path: [UInt8](repeating: 0, count: 16), depth: 0).networks
    }

    /// Networks in the subtree matching this country; `whole` indicates the entire subtree matches (parent merges both halves into one)
    private func walk(_ node: Int, path: [UInt8], depth: Int) throws(CountryDatabaseError) -> (networks: [IPNetwork], whole: Bool) {
        if node == ipv4Root, path.count == 16 {
            // Only traverse as IPv4 at ::/96; skip at aliases
            guard depth == 96, path.allSatisfy({ $0 == 0 }) else { return ([], false) }
            // Do not report `whole` upwards: IPv4 networks cannot be merged with neighboring IPv6 networks
            return (try walk(node, path: [0, 0, 0, 0], depth: 0).networks, false)
        }
        guard depth < path.count * 8, !visited[node] else { throw .malformed }
        visited[node] = true
        var halves: [(networks: [IPNetwork], whole: Bool)] = []
        for bit in 0...1 {
            var p = path
            if bit == 1 { p[depth / 8] |= 0x80 >> UInt8(depth % 8) }
            let child = try record(node, bit)
            if child < nodeCount {
                halves.append(try walk(child, path: p, depth: depth + 1))
            } else if child == nodeCount {
                halves.append(([], false))
            } else {
                let matches = try verdict(child - nodeCount - 16)
                halves.append((matches ? [IPNetwork(bytes: p, prefix: depth + 1)!] : [], matches))
            }
        }
        if halves[0].whole, halves[1].whole { return ([IPNetwork(bytes: path, prefix: depth)!], true) }
        // Merged subtree count does not exceed limit, combined at most 2x: array will not consume excessive memory
        guard halves[0].networks.count + halves[1].networks.count <= limit else { throw .tooManyNetworks }
        return (halves[0].networks + halves[1].networks, false)
    }

    private func verdict(_ offset: Int) throws(CountryDatabaseError) -> Bool {
        if let v = verdicts[offset] { return v }
        guard try data.isMap(at: offset) else { throw .malformed }
        let countryMap = try data.field("country", inMapAt: offset)
        let code = try countryMap.flatMap { m throws(CountryDatabaseError) in try data.string(at: data.field("iso_code", inMapAt: m)) }
        let v = code?.lowercased() == country
        verdicts[offset] = v
        return v
    }

    /// Left (0) or right (1) record of node `node`
    private func record(_ node: Int, _ side: Int) throws(CountryDatabaseError) -> Int {
        let width = recordSize * 2 / 8
        let start = node * width
        guard start + width <= bytes.count else { throw .malformed }
        let b = { (i: Int) in Int(self.bytes[start + i]) }
        switch (recordSize, side) {
        case (24, 0): return b(0) << 16 | b(1) << 8 | b(2)
        case (24, _): return b(3) << 16 | b(4) << 8 | b(5)
        case (28, 0): return (b(3) & 0xF0) << 20 | b(0) << 16 | b(1) << 8 | b(2)
        case (28, _): return (b(3) & 0x0F) << 24 | b(4) << 16 | b(5) << 8 | b(6)
        case (_, 0): return b(0) << 24 | b(1) << 16 | b(2) << 8 | b(3)
        default: return b(4) << 24 | b(5) << 16 | b(6) << 8 | b(7)
        }
    }
}

/// Decodes data section. `base` is start of data section, pointers are relative to it. Only queries by key, only decodes strings and unsigned integers, skips other values: skips do not follow pointers,
/// pointers cannot point to pointers (per spec). When multiple records point to the same large map and multiple keys point to the same large string, workload multiplies,
/// so total count of value headers read plus decoded string bytes has an overall `budget` cap.
private final class Decoder {
    let bytes: [UInt8]
    let base: Int
    /// End of this section: data section ends at metadata marker, metadata ends at EOF
    let end: Int
    /// Remaining count of value headers to read and string bytes to decode. Initialized to file byte count (plus slight margin to scan metadata keys repeatedly):
    /// In a valid DB, every value is at least 1 byte, and records are cached by offset, so budget is sufficient
    private var budget: Int

    init(bytes: [UInt8], base: Int, end: Int) {
        (self.bytes, self.base, self.end, budget) = (bytes, base, end, bytes.count + 4096)
    }

    /// Header of a value at offset: type, size, body start. For pointers, "size" is target offset.
    private func header(at offset: Int) throws(CountryDatabaseError) -> (type: Int, size: Int, body: Int) {
        budget -= 1
        guard budget >= 0 else { throw .malformed }
        var i = offset
        let byte = { () throws(CountryDatabaseError) -> Int in
            guard i >= 0, self.base + i < self.end else { throw .malformed }
            defer { i += 1 }
            return Int(self.bytes[self.base + i])
        }
        let control = try byte()
        var type = control >> 5
        if type == 1 {
            let ss = control >> 3 & 0x3, vvv = control & 0x7
            let target = switch ss {
            case 0: vvv << 8 | (try byte())
            case 1: (vvv << 16 | (try byte()) << 8 | (try byte())) + 2048
            case 2: (vvv << 24 | (try byte()) << 16 | (try byte()) << 8 | (try byte())) + 526_336
            default: (try byte()) << 24 | (try byte()) << 16 | (try byte()) << 8 | (try byte())
            }
            return (1, target, i)
        }
        if type == 0 { type = 7 + (try byte()) }
        var size = control & 0x1F
        switch size {
        case 29: size = 29 + (try byte())
        case 30: size = 285 + ((try byte()) << 8 | (try byte()))
        case 31: size = 65_821 + ((try byte()) << 16 | (try byte()) << 8 | (try byte()))
        default: break
        }
        return (type, size, i)
    }

    /// Resolves pointer to actual value (single hop only)
    private func resolve(_ offset: Int) throws(CountryDatabaseError) -> (type: Int, size: Int, body: Int) {
        let h = try header(at: offset)
        guard h.type == 1 else { return h }
        let target = try header(at: h.size)
        guard target.type != 1 else { throw .malformed }
        return target
    }

    /// Skips value at offset, returns following offset. Pointers only skip themselves without following.
    private func skip(_ offset: Int, depth: Int = 0) throws(CountryDatabaseError) -> Int {
        guard depth < 32 else { throw .malformed }
        let h = try header(at: offset)
        var i = h.body
        switch h.type {
        case 1: return i
        case 7: for _ in 0..<(2 * h.size) { i = try skip(i, depth: depth + 1) }
        case 11: for _ in 0..<h.size { i = try skip(i, depth: depth + 1) }
        case 3: i += 8
        case 15: i += 4
        case 14: break
        case 2, 4, 5, 6, 8, 9, 10: i += h.size
        default: throw .malformed
        }
        guard base + i <= end else { throw .malformed }
        return i
    }

    func isMap(at offset: Int) throws(CountryDatabaseError) -> Bool { try resolve(offset).type == 7 }

    /// Offset where value for `key` in map at offset begins; returns `nil` if not a map or key not found
    func field(_ key: String, inMapAt offset: Int) throws(CountryDatabaseError) -> Int? {
        let map = try resolve(offset)
        guard map.type == 7 else { return nil }
        var i = map.body
        let wanted = Array(key.utf8)
        for _ in 0..<map.size {
            let k = try resolve(i)
            let value = try skip(i)
            // Compare length first, then byte-by-byte without decoding to String: many keys can point to same large string; length mismatch skips in one step
            if k.type == 2, k.size == wanted.count, k.body >= 0, base + k.body + k.size <= end,
               bytes[(base + k.body)..<(base + k.body + k.size)].elementsEqual(wanted) { return value }
            i = try skip(value)
        }
        return nil
    }

    func string(at offset: Int?) throws(CountryDatabaseError) -> String? {
        guard let offset else { return nil }
        let h = try resolve(offset)
        guard h.type == 2 else { return nil }
        guard h.body >= 0, base + h.body + h.size <= end else { throw .malformed }
        // Deduct budget by bytes: values of many records may point to the same large string; counting header reads alone is insufficient, ensuring total processed bytes <= file size
        budget -= h.size
        guard budget >= 0 else { throw .malformed }
        return String(decoding: bytes[(base + h.body)..<(base + h.body + h.size)], as: UTF8.self)
    }

    func uint(at offset: Int?) throws(CountryDatabaseError) -> UInt64? {
        guard let offset else { return nil }
        let h = try resolve(offset)
        guard [5, 6, 9, 10].contains(h.type), h.size <= 8 else { return nil }
        guard h.body >= 0, base + h.body + h.size <= end else { throw .malformed }
        return bytes[(base + h.body)..<(base + h.body + h.size)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
