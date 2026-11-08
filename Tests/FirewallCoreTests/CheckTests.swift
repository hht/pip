import Testing
@testable import FirewallCore

/// pfctl -sr: main ruleset actual stdout on macOS 26.5 under default /etc/pf.conf (docs/firewall.md §6)
private let mainRules = """
scrub-anchor "com.apple/*" all fragment reassemble
scrub-anchor "com.apple.internet-sharing" all fragment reassemble
anchor "com.apple/*" all
anchor "com.apple.internet-sharing" all

"""

/// pfctl -a com.apple/300.Notchkeeper -vsr, format based on actual output during rehearsal on macOS 26.5
private func anchorRules(_ evaluations: [Int]) -> String {
    evaluations.map {
        """
        pass quick on lo0 all flags S/SA keep state
          [ Evaluations: \($0)       Packets: 0         Bytes: 0           States: 0     ]
          [ Inserted: uid 0 pid 91065 ]

        """
    }.joined()
}

private let interfaces = "lo0 gif0 stf0 en0 awdl0 utun0 utun1024 bridge100\n"
/// First line of pfctl -s info, formatted based on rehearsal on macOS 26.5
private let info = "Status: Enabled for 18 days 12:22:58          Debug: Urgent\n\n"

@Suite struct Check {
    @Test func healthy() {
        let c = FirewallCheck(mainRules: mainRules, anchorRules: anchorRules([300, 26]), info: info, interfaces: interfaces,
                              tunnel: "utun1024", previousEvaluations: 100)
        #expect(c == FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 326,
                                   evaluationsGrowing: true, tunnelPresent: true))
        #expect(c.passed)
    }

    private func check(main: String = mainRules, anchor: String = anchorRules([300, 26]), info i: String = info,
                       interfaces ifs: String = interfaces, previous: UInt64? = 100) -> FirewallCheck {
        FirewallCheck(mainRules: main, anchorRules: anchor, info: i, interfaces: ifs, tunnel: "utun1024", previousEvaluations: previous)
    }

    /// fail-open: if pfctl -d disabled pf, rules in anchor do not take effect; unreadable output (empty) also fails.
    /// Disabled vs unreadable are separated: former means our reference was definitely revoked, latter proves nothing.
    @Test(arguments: [("Status: Disabled          Debug: Urgent\n", false), ("", nil)] as [(String, Bool?)])
    func pfNotEnabled(_ info: String, enabled: Bool?) {
        let c = check(info: info)
        #expect(c.pfEnabled == enabled)
        #expect(!c.passed)
    }

    /// fail-open: if pfctl -f replaced main ruleset, this anchor is no longer evaluated
    @Test func anchorPointGone() {
        let c = check(main: "anchor \"com.apple.internet-sharing\" all\npass all\n")
        #expect(!c.anchorPointPresent)
        #expect(!c.passed)
    }

    @Test func noRules() {
        let c = check(anchor: "")
        #expect(!c.rulesLoaded)
        #expect(c.evaluations == nil)
        #expect(!c.passed)
    }

    /// Evaluations not growing: rules present, but not evaluated
    @Test func evaluationsNotGrowing() {
        let c = check(previous: 326)
        #expect(c.evaluationsGrowing == false)
        #expect(!c.passed)
    }

    /// Interface name misspelled or Clash changed name: fails safe, but must be reported
    @Test func tunnelMissing() {
        let c = check(interfaces: "lo0 en0 utun0 utun10240\n")
        #expect(!c.tunnelPresent)
        #expect(!c.passed)
    }

    /// Freshly loaded without previous round to compare: does not count as failure
    @Test func firstRoundAfterLoadPasses() {
        let c = check(previous: nil)
        #expect(c.evaluationsGrowing == nil)
        #expect(c.passed)
    }

    /// Format changed and number unreadable: must not permanently pass
    @Test func unreadableEvaluationsFail() {
        let c = check(anchor: anchorRules([300]) + "pass out all\n  [ Evaluations: lots ]\n", previous: nil)
        #expect(c.evaluations == nil)
        #expect(!c.passed)
    }
}

@Suite struct EnableOutput {
    /// Actual output of pfctl -E during rehearsal on macOS 26.5: stdout empty, token in stderr
    @Test func readsTheToken() {
        let stderr = "No ALTQ support in kernel\nALTQ related functions disabled\npf enabled\nToken : 1864012227745836441\n"
        #expect(PFOutput.token(fromEnable: stderr) == "1864012227745836441")
    }

    @Test(arguments: ["pf enabled\n", "Token : \n", "Token : 12ab\n", "Token : 1\nToken : 2\n"])
    func unrecognizedIsNil(_ stderr: String) {
        #expect(PFOutput.token(fromEnable: stderr) == nil)
    }
}

@Suite struct ReferencesOutput {
    /// Actual stdout of pfctl -s References during rehearsal on macOS 26.5
    @Test func readsTokens() {
        let out = """
        TOKENS:
        PID      Process Name                 TOKEN                    TIMESTAMP
        91055    pfctl                        1864012227745836441      0 days 00:00:12
        49256    pfd                          12184426722627826779     18 days 12:23:10

        """
        #expect(PFOutput.tokens(fromReferences: out) == ["1864012227745836441", "12184426722627826779"])
    }

    /// Process name containing spaces parsed correctly: token is column before timestamp (3 columns)
    @Test func processNameWithSpaces() {
        let out = "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n812      Internet Sharing             42                       1 days 01:02:03\n"
        #expect(PFOutput.tokens(fromReferences: out) == ["42"])
    }

    @Test func noReferences() {
        #expect(PFOutput.tokens(fromReferences: "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n") == [])
    }

    /// Unrecognized format (missing header, mismatched line) is unreadable, not "empty": treating as empty would cause daemon to re-run -E every round
    @Test(arguments: ["", "pfctl: DIOCGETSTARTERS: Permission denied\n",
                      "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\ngarbage line\n",
                      "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n91055    pfctl    1864012227745836441    0 hours 00:00:12\n"])
    func unrecognizedIsNil(_ out: String) {
        #expect(PFOutput.tokens(fromReferences: out) == nil)
    }
}
