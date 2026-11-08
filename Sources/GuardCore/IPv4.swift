/// Answers: is a string a valid dotted-decimal IPv4 address.
/// External data (probe responses, allowlists) parsed into it at boundaries, internally compared by value.
public struct IPv4: Hashable, Sendable, CustomStringConvertible {
    public let octets: [UInt8]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            // ASCII digits only, at most 3 chars; Unicode digits, "+1", and leading zeros ("010") rejected to prevent normalization
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0",
                  let n = UInt8(part) else { return nil }
            octets.append(n)
        }
        self.octets = octets
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }
}
