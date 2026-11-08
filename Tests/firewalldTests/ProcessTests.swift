import Foundation
import Testing
@testable import firewalld

@Suite struct RunProcess {
    /// Rules fed via stdin, output collected from stdout/stderr, exit code reported truthfully
    @Test func passesInputAndCollectsOutput() {
        let out = FirewallSystem.runProcess("/bin/sh", ["-c", "cat; echo oops >&2; exit 3"], "pass all\n", timeout: 5)
        #expect(out.status == 3)
        #expect(out.stdout == "pass all\n")
        #expect(out.stderr == "oops\n")
    }

    /// Subcommands run under root do not inherit caller environment: when sudo preserves user HOME, dig would read user-writable ~/.digrc (equivalent to injecting flags)
    @Test func childrenGetAMinimalEnvironment() {
        let out = FirewallSystem.runProcess("/usr/bin/env", [], nil, timeout: 5)
        #expect(out.stdout.split(separator: "\n").sorted() == ["HOME=/var/root", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// Hung subcommands are terminated on timeout and treated as failure, guaranteeing a round always finishes
    @Test func killsACommandThatHangs() {
        let started = ContinuousClock.now
        let out = FirewallSystem.runProcess("/bin/sleep", ["30"], nil, timeout: 0.2)
        #expect(out.status == -1)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
