import Foundation
import Testing
@testable import Notchkeeper

/// Shell line passed to administrator prompt: root copies script into private temp dir and verifies hash before execution.
@Suite struct FirewallPrivilegedCommand {
    private let hash = String(repeating: "a", count: 64)

    /// Run directly via /bin/sh (unprivileged): refuses execution if script tampered with, executes with arguments if matching.
    @Test func runsOnlyTheScriptThatWasStaged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw cmd '\(UUID().uuidString)'") // Spaces and quotes
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("s.sh")
        try Data("echo \"ran $1 $2\"\n".utf8).write(to: script)
        let good = try FirewallInstaller.sha256(of: script)

        let ran = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: good, arguments: ["a b", "it's"]))
        #expect(ran.status == 0 && ran.out == "ran a b it's\n")

        let refused = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: hash, arguments: []))
        #expect(refused.status != 0 && !refused.out.contains("ran"))

        // Symlinks are rejected even if pointing to valid script.
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        #expect(try sh(FirewallInstaller.privilegedCommand(script: link, sha256: good, arguments: [])).status != 0)
    }

    /// Script run as root must not inherit caller's environment (e.g. BASH_ENV causes bash to source a file first).
    @Test func environmentIsCleared() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("s.sh")
        try Data("echo \"bash_env=${BASH_ENV:-} secret=${SECRET:-}\"\n".utf8).write(to: script)
        let injected = dir.appendingPathComponent("inject.sh")
        try Data("echo injected\n".utf8).write(to: injected)
        let r = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: FirewallInstaller.sha256(of: script), arguments: []),
                       environment: ["BASH_ENV": injected.path, "SECRET": "x"])
        #expect(r.status == 0 && r.out == "bash_env= secret=\n")
        // Hash verification step must not inherit caller environment either: /usr/bin/shasum is a Perl script reading PERL5OPT.
        let perl = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: FirewallInstaller.sha256(of: script), arguments: []),
                          environment: ["PERL5OPT": "-MNoSuchModuleInjected"])
        #expect(perl.status == 0 && perl.out == "bash_env= secret=\n")
    }

    private func sh(_ command: String, environment: [String: String]? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }
}
