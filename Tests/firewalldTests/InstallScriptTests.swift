import Foundation
import Testing
import FirewallCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
/// Prebuilt helper by `swift test`: the App bundles such a prebuilt helper, never compiling under root
private let helper = root.appendingPathComponent(".build/debug/firewalld")

/// Runs installation script (no root required: only uses --dry-run or flags that exit before root check)
private func install(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [root.appendingPathComponent("scripts/install-firewall.sh").path] + args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, o, e)
}

private func sha256(_ url: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256", url.path]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return String(text.prefix(64))
}

/// Installing production rules in App: provide prebuilt helper and its hash, avoid compiling under root; stop on hash mismatch
@Suite(.serialized) struct InstallScript {
    @Test func officialRulesDryRunWithPrebuiltHelper() throws {
        let hash = try sha256(try #require(FileManager.default.fileExists(atPath: helper.path) ? helper : nil))
        let r = try install(["--helper", helper.path, "--expect-sha256", hash, "--dry-run"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("sha256 \(hash)"))
        // Production rules: final rule blocks all outbound, no test table; LaunchDaemon without --test-rules
        #expect(r.out.contains("block return out quick all"))
        #expect(!r.out.contains("<test>") && !r.out.contains("--test-rules") && !r.out.contains(FirewallRules.testTableFile))
        #expect(!r.out.contains("compile"))
    }

    @Test func hashMismatchStops() throws {
        let r = try install(["--helper", helper.path, "--expect-sha256", String(repeating: "0", count: 64), "--dry-run"])
        #expect(r.status != 0)
        #expect(r.err.localizedCaseInsensitiveContains("hash"))
        #expect(!r.out.contains("Rules syntax valid"))
    }

    /// root reading --helper does not follow symlinks: links to other files are rejected
    @Test func symlinkedHelperRefused() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("helper-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        defer { try? FileManager.default.removeItem(at: link) }
        let r = try install(["--helper", link.path, "--expect-sha256", try sha256(helper), "--dry-run"])
        #expect(r.status != 0 && r.err.contains("not a regular file"))
    }

    @Test func testRulesStillAvailable() throws {
        let hash = try sha256(helper)
        let r = try install(["--test-rules", "--test-address", "198.51.100.7", "--helper", helper.path, "--expect-sha256", hash, "--dry-run"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("<test>") && r.out.contains("--test-rules"))
    }

    /// Skipping yes prompt is only allowed when caller pins the hash
    @Test(arguments: [["--yes", "--helper", "/x"], ["--test-address", "198.51.100.7"], ["--expect-sha256", "abc", "--helper", "/x"],
                      ["--test-rules"]])
    func badArguments(_ args: [String]) throws {
        let r = try install(args + ["--dry-run"])
        #expect(r.status != 0)
        #expect(!r.out.contains("Rules syntax valid"))
    }
}
