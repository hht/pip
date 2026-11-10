import Foundation
import Testing
@testable import NotchCore

/// "Open URL" on cards allows https by default; schemes added by user in settings are also allowed.
/// Custom schemes can trigger actions in other apps, so any scheme not in allowlist is blocked
@Suite struct URLPolicyRules {
    @Test(arguments: ["https://example.com/x", "HTTPS://example.com"])
    func httpsAlwaysAllowed(_ s: String) {
        #expect(URLPolicy(schemes: []).allows(URL(string: s)!))
    }

    @Test(arguments: ["http://example.com", "file:///etc/hosts", "javascript:alert(1)", "raycast://extensions/x", "btt://trigger_named/?x"])
    func othersBlockedByDefault(_ s: String) {
        #expect(!URLPolicy(schemes: []).allows(URL(string: s)!))
    }

    /// Allowlist entries as "Raycast" or "raycast://" resolve to the same scheme
    @Test(arguments: ["raycast", "Raycast", "raycast://", " raycast "])
    func whitelistedSchemeAllowed(_ entry: String) {
        let policy = URLPolicy(schemes: [entry])
        #expect(policy.allows(URL(string: "raycast://extensions/x")!))
        #expect(!policy.allows(URL(string: "btt://x")!))
    }
}

/// Erroneous entries (empty string) cannot become allowed; pinning edge cases
@Suite struct URLPolicyEdges {
    @Test(arguments: ["", "://", " "])
    func emptyEntryAllowsNothing(_ entry: String) {
        #expect(!URLPolicy(schemes: [entry]).allows(URL(string: "://x")!))
    }

    @Test func oddURLs() {
        let p = URLPolicy(schemes: [])
        #expect(!p.allows(URL(string: "javascript:https://x")!))
        #expect(URL(string: "HTTPS ://x") == nil)
        // https without host allowed: at worst browser opens invalid link
        #expect(p.allows(URL(string: "https:")!))
    }
}

/// Settings view new allowlist entry: normalized to lowercase, strips "://"; rejects non-RFC 3986 scheme syntax
@Suite struct URLPolicySchemeEntry {
    @Test(arguments: [("Raycast", "raycast"), ("raycast://", "raycast"), (" x-callback+v1.2 ", "x-callback+v1.2")])
    func normalized(_ entry: String, _ scheme: String) {
        #expect(URLPolicy.scheme(entry) == scheme)
    }

    @Test(arguments: ["", "://", "1abc", "ray cast", "http:", "a/b", "https"])
    func rejected(_ entry: String) {
        #expect(URLPolicy.scheme(entry) == nil)
    }
}
