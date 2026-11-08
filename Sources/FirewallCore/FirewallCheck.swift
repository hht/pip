/// Answers: whether the active firewall is truly blocking traffic right now (docs/firewall.md §4 "Verification", §5 "fail-open").
/// If any check fails, the App cannot display "Protected". Parses pfctl / ifconfig output only, unaware of how they are invoked.
public struct FirewallCheck: Codable, Equatable, Sendable {
    /// pf is enabled (`pfctl -s info` shows `Status: Enabled`): if someone runs pfctl -d, rules remaining in the anchor do not take effect.
    /// `nil` means unreadable: distinct from definitively disabled; disabled indicates all references were revoked.
    public var pfEnabled: Bool?
    /// Main ruleset contains `anchor "com.apple/*"`: if someone replaces main ruleset via `pfctl -f`, this anchor is no longer evaluated.
    public var anchorPointPresent: Bool
    /// This anchor has rules loaded
    public var rulesLoaded: Bool
    /// Sum of Evaluations across all rules in this anchor; `nil` if count cannot be parsed
    public var evaluations: UInt64?
    /// Increased compared to last round: this anchor is actively being evaluated. `nil` means no previous round to compare against (freshly loaded, reloaded, or unreadable count)
    public var evaluationsGrowing: Bool?
    /// TUN interface is present: if interface name is wrong or Clash changed name, rules will block all traffic (failing closed/safely), which must be visible to the user.
    public var tunnelPresent: Bool

    public init(pfEnabled: Bool?, anchorPointPresent: Bool, rulesLoaded: Bool, evaluations: UInt64?, evaluationsGrowing: Bool?, tunnelPresent: Bool) {
        self.pfEnabled = pfEnabled
        self.anchorPointPresent = anchorPointPresent
        self.rulesLoaded = rulesLoaded
        self.evaluations = evaluations
        self.evaluationsGrowing = evaluationsGrowing
        self.tunnelPresent = tunnelPresent
    }

    /// - Parameters:
    ///   - mainRules: stdout of `pfctl -sr`, anchor point is line `anchor "com.apple/*" all` (verified on macOS); matches up to closing quote so `anchor "com.apple.internet-sharing"` does not match
    ///   - anchorRules: stdout of `pfctl -a <anchor> -vsr`, each rule is followed by line `[ Evaluations: <n> ... ]`
    ///   - info: stdout of `pfctl -s info`, first line is `Status: Enabled ...` or `Status: Disabled ...` (verified on macOS)
    ///   - interfaces: stdout of `ifconfig -l`
    ///   - previousEvaluations: previous round's `evaluations`
    /// If any command fails, caller passes empty string: all checks will fail.
    public init(mainRules: String, anchorRules: String, info: String, interfaces: String, tunnel: String, previousEvaluations: UInt64?) {
        pfEnabled = info.hasPrefix("Status: Enabled") ? true : info.hasPrefix("Status: Disabled") ? false : nil
        anchorPointPresent = mainRules.split(separator: "\n").contains { $0.hasPrefix(#"anchor "com.apple/*""#) }
        let lines = anchorRules.split(separator: "\n")
        let ruleCount = lines.filter { !$0.hasPrefix(" ") }.count
        let counts = lines.compactMap { line -> UInt64? in
            let words = line.split(separator: " ")
            return words.firstIndex(of: "Evaluations:").flatMap { words.indices.contains($0 + 1) ? UInt64(words[$0 + 1]) : nil }
        }
        rulesLoaded = ruleCount > 0
        // Every rule must have a readable number, missing even one invalidates the sum; &+ will not crash the root daemon on overflow
        evaluations = rulesLoaded && counts.count == ruleCount ? counts.reduce(0, &+) : nil
        evaluationsGrowing = evaluations.flatMap { now in previousEvaluations.map { now > $0 } }
        tunnelPresent = interfaces.split(whereSeparator: \.isWhitespace).contains { $0 == tunnel }
    }

    /// All must pass to be considered active blocking. No previous round to compare (`evaluationsGrowing == nil`) is not a failure: the round immediately after loading should not report anomaly;
    /// unreadable Evaluations numbers count as failure, otherwise format changes would permanently pass without verification.
    public var passed: Bool { tunnelPresent && passedApartFromTunnel }

    /// Rules are actively being evaluated, missing only the tunnel interface: in this case everything is blocked (fails safe). When pf is stopped or anchor is empty, nothing is blocked, which is distinct.
    public var passedApartFromTunnel: Bool {
        pfEnabled == true && anchorPointPresent && rulesLoaded && evaluations != nil && evaluationsGrowing != false
    }
}

/// Answers: parsing pfctl command output. Formats based on local macOS testing (docs/firewall.md §6)
public enum PFOutput {
    /// Stderr of `pfctl -E` contains exactly one line `Token : <digits>`; returns `nil` if unrecognized (missing, non-digit, or multiple lines).
    public static func token(fromEnable stderr: String) -> String? {
        let tokens = stderr.split(separator: "\n").compactMap { line -> Substring? in
            guard line.hasPrefix("Token : ") else { return nil }
            return line.dropFirst("Token : ".count)
        }
        guard tokens.count == 1, let t = tokens.first, !t.isEmpty, t.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return String(t)
    }
}

extension PFOutput {
    /// Extracts tokens present in stdout of `pfctl -s References`. Each line has PID, process name, token, `<n> days HH:MM:SS`;
    /// process name may contain spaces, so token is 4th column from end of line. Returns `nil` if format unrecognized (no header or line mismatch), rather than empty set.
    public static func tokens(fromReferences stdout: String) -> Set<String>? {
        let lines = stdout.split(separator: "\n")
        guard let header = lines.firstIndex(where: { $0.hasPrefix("PID") }) else { return nil }
        var tokens: Set<String> = []
        for line in lines[(header + 1)...] {
            let fields = line.split(separator: " ")
            guard fields.count >= 5, fields[fields.count - 2] == "days",
                  case let t = fields[fields.count - 4], t.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            tokens.insert(String(t))
        }
        return tokens
    }
}
