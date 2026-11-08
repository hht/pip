import Darwin

/// Answers: an IPv4 or IPv6 network (a single address is a full-prefix network), populated into allow tables.
/// Agnostic of origin (Clash configuration, DNS answers, mmdb).
public struct IPNetwork: Hashable, Sendable, CustomStringConvertible {
    /// 4 or 16 bytes, network byte order; host bits not cleared, preserved as written
    public let bytes: [UInt8]
    public let prefix: Int

    public init?(bytes: [UInt8], prefix: Int) {
        guard bytes.count == 4 || bytes.count == 16, (0...bytes.count * 8).contains(prefix) else { return nil }
        (self.bytes, self.prefix) = (bytes, prefix)
    }

    /// `198.51.100.7`, `198.51.100.0/24`, `2001:db8::/32`; others return `nil`
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        var v4 = in_addr(), v6 = in6_addr()
        let bytes: [UInt8]
        if inet_pton(AF_INET, address, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, address, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
        var prefix = bytes.count * 8
        if parts.count == 2 {
            guard let p = Int(parts[1]), parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber) else { return nil }
            prefix = p
        }
        self.init(bytes: bytes, prefix: prefix)
    }

    /// `other` completely enclosed within this network (same family)
    public func contains(_ other: IPNetwork) -> Bool {
        guard other.bytes.count == bytes.count, other.prefix >= prefix else { return false }
        for bit in 0..<prefix where (bytes[bit / 8] ^ other.bytes[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 {
            return false
        }
        return true
    }

    /// `address/prefix`, format recognized by pfctl table files
    public var description: String { "\(address)/\(prefix)" }

    /// Address without prefix
    public var address: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let printed = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        guard printed != nil else { preconditionFailure("4 or 16 bytes must always print") }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
