import Foundation

/// Answers: Whether "Open URL" on a card can be opened. Allows https by default; also allows schemes listed in `urlSchemes` (Settings > Plugins).
/// Custom schemes (like raycast://, btt://) can launch apps and execute actions, so unlisted schemes are blocked.
/// Evaluates permission only; does not open URLs, agnostic of cards
public struct URLPolicy: Sendable {
    private let schemes: Set<String>

    /// schemes: Allowlist, accepts "Raycast" or "raycast://"; invalid entries ignored (cannot become allowed), config.json hand-edits parsed via `scheme(_:)`
    public init(schemes: [String]) {
        self.schemes = Set(schemes.compactMap(Self.scheme))
    }

    /// Single allowlist entry: lowercase, strips "://"; rejects non-RFC 3986 scheme syntax (starts with letter, followed by letters, digits, +, -, .) and https (allowed by default)
    /// @see https://www.rfc-editor.org/rfc/rfc3986#section-3.1
    public static func scheme(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix("://") { s.removeLast(3) }
        guard let first = s.unicodeScalars.first, ("a"..."z").contains(first), s != "https",
              s.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        return s
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || schemes.contains(scheme)
    }
}
