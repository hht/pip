import Foundation
import Testing
import FirewallCore
@testable import firewalld

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Rescue script does not depend on helper; paths are written independently in each:
/// run with --dry-run (no root, modifies nothing), ensuring it cleans everything left by helper
@Suite struct RescueScript {
    private func dryRun() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/firewall-rescue.sh").path, "--dry-run"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return text
    }

    @Test func cleansEverythingTheHelperLeaves() throws {
        let text = try dryRun()
        #expect(text.contains("launchctl bootout system/\(FirewallPaths.label)"))
        #expect(text.contains("pfctl -a \(FirewallPaths.anchor) -F rules"))
        let dir = FirewallPaths.directory.path
        for name in [FirewallState.fileName, FirewallStatus.fileName, FirewallPaths.lockFile,
                     ".\(FirewallState.fileName).tmp", ".\(FirewallStatus.fileName).tmp",
                     FirewallRules.clashTableFile, FirewallRules.cnTableFile, FirewallRules.testTableFile,
                     ".\(FirewallRules.clashTableFile).tmp", ".\(FirewallRules.cnTableFile).tmp"] {
            #expect(text.contains("rm -f \(dir)/\(name)"), "Rescue script did not clean \(name)")
        }
        #expect(text.contains("rm -f /Library/LaunchDaemons/\(FirewallPaths.label).plist"))
    }

    /// When pf hangs inside kernel (user rule deadlock, docs/firewall.md §5), pfctl calls don't return, and launchctl bootout may also block:
    /// delete plist and helper loaded at boot first (file operations only), guaranteeing recovery on reboot regardless of where it hangs
    @Test func removesWhatLoadsAtBootBeforeTouchingPF() throws {
        let text = try dryRun()
        let plist = try #require(text.range(of: "rm -f /Library/LaunchDaemons/\(FirewallPaths.label).plist"))
        let helper = try #require(text.range(of: "rm -f /Library/PrivilegedHelperTools/notchkeeper-firewall"))
        let bootout = try #require(text.range(of: "launchctl bootout"))
        let pfctl = try #require(text.range(of: "pfctl -"))
        #expect(plist.lowerBound < bootout.lowerBound && plist.lowerBound < pfctl.lowerBound)
        #expect(helper.lowerBound < bootout.lowerBound && helper.lowerBound < pfctl.lowerBound)
    }

    /// Limited execution: stuck command (here simulated with sleep) gives up within seconds and returns 124, output still captured.
    /// Extracts `limited` function verbatim from script for testing
    @Test func limitedGivesUpOnAHungCommand() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/firewall-rescue.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "limited() {"))
        let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("limited-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", function + """
            limited 1 "$1" sh -c 'echo started; exec sleep 30'; echo "hung=$?"
            limited 1 "$1" echo done; echo "quick=$? $(cat "$1")"
            """, "limited-test", out]
        let pipe = Pipe()
        p.standardOutput = pipe
        let started = ContinuousClock.now
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(text.contains("hung=124"))
        #expect(text.contains("quick=0 done"))
    }

    /// Installer syntax check: extracts `check_syntax` verbatim and runs under macOS system /bin/bash (3.2), feeding test rules.
    /// bash 3.2 leaves quotes in `${…//pattern/"replacement"}` verbatim, corrupting table file paths to `""/private/tmp/…"`, causing pfctl cannot load error
    @Test func installerSyntaxCheckRunsOnSystemBash() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install-firewall.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "check_syntax() {"))
        let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let rules = try #require(FirewallRules(tunnel: "utun1024", scope: .testTable, directory: FirewallPaths.directory.path)).text
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "SUPPORT='\(FirewallPaths.directory.path)'; ANCHOR='\(FirewallPaths.anchor)'\n" + function + "check_syntax \"$1\" \"$2\"",
                       "syntax-test", rules, dir.path]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"] // Same as script: does not rely on caller PATH for pfctl
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(stderr)")
    }

    /// Installer must recognize everything rescue script removes; rejects anything rescue script would delete.
    /// Both written independently, compared line by line: 6 path lines plus `FILES=(` to `)` list
    @Test func installerUsesTheRescuePaths() throws {
        func paths(_ script: String) throws -> [Substring] {
            let lines = try String(contentsOf: root.appendingPathComponent("scripts/\(script)"), encoding: .utf8).split(separator: "\n")
            let names = lines.filter { ["LABEL=", "ANCHOR=", "PLIST=", "HELPER=", "SUPPORT=", "STATE="].contains(where: $0.hasPrefix) }
            guard let start = lines.firstIndex(where: { $0.hasPrefix("FILES=(") }),
                  let end = lines[start...].firstIndex(where: { $0.hasSuffix(")") }) else { return names }
            return names + lines[start...end]
        }
        let rescue = try paths("firewall-rescue.sh")
        #expect(rescue.count == 9)
        #expect(try paths("install-firewall.sh") == rescue)
    }
}
