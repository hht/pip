import Darwin
import Foundation
import FirewallCore

/// Answers: how to snapshot allow tables upon enabling — reads two files from Clash Verge directory, queries DNS,
/// and writes the two tables into root directory (docs/firewall.md §4).
/// Policy logic (which fields to read, which subnets count as domestic, validity of answers) resides in FirewallCore;
/// caller decides timing (only enable command calls this).
struct AllowTables {
    var clash: [IPNetwork]
    var cn: [IPNetwork]

    /// File size upper bounds: genuine config is ~200 KB, mmdb is ~9 MB; anything larger is invalid (also avoids stalls from huge files)
    private static let maxConfigSize = 8 << 20, maxDatabaseSize = 64 << 20

    static func take(from clash: URL, _ sys: FirewallSystem) throws(SnapshotFailure) -> AllowTables {
        let yaml = try read("clash-verge.yaml", in: clash, limit: maxConfigSize)
        let database = try read("Country.mmdb", in: clash, limit: maxDatabaseSize)
        let config: ClashRuntimeConfig
        do { config = try ClashRuntimeConfig(yaml: String(decoding: yaml, as: UTF8.self)) } catch { throw .config(error) }
        let cn: [IPNetwork]
        do { cn = try CountryDatabase.networks(country: "CN", in: database) } catch { throw .database(error) }
        guard !cn.isEmpty else { throw .noCountryNetworks }
        guard CountryDatabase.isPlausible(cn) else { throw .implausibleCountryNetwork }
        do {
            let limit = CountryDatabase.maxTableEntries - cn.count
            return AllowTables(clash: try config.clashTable(limit: limit) { name, server in resolve(name, server, sys) }, cn: cn)
        } catch {
            throw .table(error)
        }
    }

    /// Writes one file per table, root 0644, one subnet per line (pfctl table file format)
    func write(to directory: URL) throws {
        for (name, networks) in [(FirewallRules.clashTableFile, clash), (FirewallRules.cnTableFile, cn)] {
            try AtomicFile.write(Data(networks.map { "\($0)\n" }.joined().utf8), to: directory.appendingPathComponent(name), mode: 0o644)
        }
    }

    /// root reading user-writable directory: does not follow symlinks (could point to root-only files or /dev/zero),
    /// reads regular files only (FIFO would block), measures size on opened fd, reads up to limit; file swapped after stat cannot be read
    private static func read(_ name: String, in directory: URL, limit: Int) throws(SnapshotFailure) -> [UInt8] {
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw .unreadable(name) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw .unreadable(name) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + count, $0.count - count) }
            guard n >= 0 else { throw .unreadable(name) } // Error during read: truncated config would miss nodes, rejected
            if n == 0 { break }
            count += n
        }
        return Array(bytes.prefix(count))
    }

    /// Uses system dig to query a plaintext UDP upstream for both A and AAAA records; `nil` if both fail.
    /// `name` has been verified as a domain name by `clashTable` (cannot be parsed as flags by dig)
    private static func resolve(_ name: String, _ server: DNSServer, _ sys: FirewallSystem) -> [IPNetwork]? {
        let answers = ["A", "AAAA"].compactMap { type -> [IPNetwork]? in
            let out = sys.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "-p", String(server.port), "@\(server.address.address)",
                                               "-t", type, "-q", name], nil)
            // +short lists answers only: addresses, or CNAME targets (ends in dot, not an IP, skipped)
            return out.succeeded ? out.stdout.split(separator: "\n").compactMap { IPNetwork(String($0)) } : nil
        }
        return answers.isEmpty ? nil : answers.flatMap { $0 }
    }
}

/// Cannot take snapshot: enable rejected, state unchanged
enum SnapshotFailure: Error, Equatable {
    /// Cannot read file in Clash Verge directory (or size implausible)
    case unreadable(String)
    case config(ClashConfigError)
    case database(CountryDatabaseError)
    /// Database readable but contains zero CN subnets (format changed): allowing would break all DIRECT traffic
    case noCountryNetworks
    /// Domestic subnet implausibly large (database tampered): allowing would leave firewall ineffective
    case implausibleCountryNetwork
    case table(AllowTableError)
}
