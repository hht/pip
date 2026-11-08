import CryptoKit
import FirewallCore
import Foundation

/// Answers: Whether the firewall is installed and its current state; how to install, uninstall, enable, keep, and disable from the App (docs/firewall.md §4 "Privileged Portion", "App"). Every state change requires the system administrator password dialog.
/// Install: Copies bundled helper and install script to /private/tmp (privileged process cannot read ~/Documents due to TCC), runs as root via administrator prompt;
/// root copies script into its own private directory, verifies SHA256 hash, and install script verifies helper SHA256; aborts if modified after staging.
/// Uninstall: Same approach running rescue script (same script run in terminal during network isolation). Enable, Keep, Disable: privileged execution of installed helper tool (owned by root, cannot be replaced).
/// App retains no persistent privileged code, reading only status summaries.
enum FirewallInstaller {
    /// Matches paths in both scripts (`RescueScriptTests` compares between scripts; used here to determine installation state).
    static let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.notchkeeper.firewall.plist")
    static let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/notchkeeper-firewall")
    /// root 0644, daemon writes each round (`FirewallStatus`).
    static let statusFile = URL(fileURLWithPath: "/Library/Application Support/Notchkeeper").appendingPathComponent(FirewallStatus.fileName)
    /// On enable, helper reads runtime configuration and GeoIP database from here to compile allowlist (docs/firewall.md §4).
    static let clashVerge = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")

    /// Considered installed if any component exists; uninstall purges all of them. Includes root directory: if remnants like status file remain, install script rejects and App must offer "Uninstall".
    static var isInstalled: Bool {
        [plist, helper, statusFile.deletingLastPathComponent()].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Current reading, and round timestamp of summary (used to wait for daemon cycle completion after commands).
    static func reading(now: Date) -> (reading: FirewallReading, checkedAt: Date?) {
        let summary: FirewallReading.Summary
        var checkedAt: Date?
        do {
            let status = try FirewallStatus.decode(Data(contentsOf: statusFile))
            summary = .read(status)
            checkedAt = status.checkedAt
        } catch CocoaError.fileReadNoSuchFile {
            summary = .missing
        } catch {
            summary = .unreadable
        }
        return (FirewallReading(installed: isInstalled, summary: summary, now: now), checkedAt)
    }

    static func enable() async throws -> Outcome {
        guard FileManager.default.fileExists(atPath: clashVerge.path) else {
            throw Failure(errorDescription: String(localized: "Can’t find Clash Verge’s config folder: turning on reads the proxy nodes and China IP ranges from it"))
        }
        return try await privileged(helperCommand(["enable", "--clash", clashVerge.path]),
                                    prompt: String(localized: "Pip wants to turn the firewall on, starting with a 2-minute trial."))
    }

    static func keep() async throws -> Outcome {
        try await privileged(helperCommand(["keep"]), prompt: String(localized: "Pip wants to keep the firewall on: it stays on, even after a restart."))
    }

    static func disable() async throws -> Outcome {
        try await privileged(helperCommand(["disable"]), prompt: String(localized: "Pip wants to turn the firewall off."))
    }

    /// Bundle staged to /private/tmp along with hashes computed at staging: root executes only matching files.
    struct Staged: Sendable {
        let directory: URL
        let helper: URL
        let helperSHA256: String
        let installScript: URL
        let installSHA256: String
        let rescueScript: URL
        let rescueSHA256: String
    }

    enum Outcome: Sendable {
        case done
        /// User cancelled password prompt.
        case cancelled
    }

    static func stage() throws -> Staged {
        guard let bundledHelper = Bundle.main.url(forAuxiliaryExecutable: "firewalld"),
              let scripts = Bundle.main.resourceURL?.appendingPathComponent("firewall", isDirectory: true),
              FileManager.default.fileExists(atPath: scripts.appendingPathComponent("install-firewall.sh").path)
        else { throw Failure(errorDescription: String(localized: "This build doesn’t include the firewall; package it with scripts/run.sh")) }
        // 0700: prevents other users modifying contents; root still verifies hashes to guard against same-user tampering.
        let dir = URL(fileURLWithPath: "/private/tmp/notchkeeper-firewall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default
        let helper = dir.appendingPathComponent("firewalld")
        try fm.copyItem(at: bundledHelper, to: helper)
        let install = dir.appendingPathComponent("install-firewall.sh")
        try fm.copyItem(at: scripts.appendingPathComponent("install-firewall.sh"), to: install)
        let rescue = dir.appendingPathComponent("firewall-rescue.sh")
        try fm.copyItem(at: scripts.appendingPathComponent("firewall-rescue.sh"), to: rescue)
        return Staged(directory: dir, helper: helper, helperSHA256: try sha256(of: helper), installScript: install, installSHA256: try sha256(of: install),
                      rescueScript: rescue, rescueSHA256: try sha256(of: rescue))
    }

    /// Discard immediately after use; failure leaves harmless directory in /private/tmp cleared on reboot.
    static func discard(_ staged: Staged) {
        do { try FileManager.default.removeItem(at: staged.directory) } catch { Log.write("Firewall: failed to delete temp directory: \(error.localizedDescription)") }
    }

    static func install(_ s: Staged, tunnel: String) async throws -> Outcome {
        try await privileged(privilegedCommand(script: s.installScript, sha256: s.installSHA256,
                                               arguments: ["--tunnel", tunnel, "--helper", s.helper.path, "--expect-sha256", s.helperSHA256, "--yes"]),
                             prompt: String(localized: "Pip wants to install the firewall (it starts off and blocks nothing)."))
    }

    static func uninstall(_ s: Staged) async throws -> Outcome {
        try await privileged(privilegedCommand(script: s.rescueScript, sha256: s.rescueSHA256, arguments: []),
                             prompt: String(localized: "Pip wants to uninstall the firewall: remove its daemon, rules, and files."))
    }

    /// Installed helper tool is owned by root and cannot be replaced; execute directly.
    private static func helperCommand(_ arguments: [String]) -> String {
        "/usr/bin/env -i \(cleanEnvironment) " + ([helper.path] + arguments).map(quoted).joined(separator: " ")
    }

    /// Shell command executed by root: script must be regular file (no symlinks, no FIFOs, <= 1 MB), copied into root's private temp dir, verified via hash before execution.
    /// Runs in /private/tmp: privileged process cannot enter ~/Documents (TCC).
    /// Executes under clean environment: shasum is a Perl script reading PERL5OPT.
    static func privilegedCommand(script: URL, sha256: String, arguments: [String]) -> String {
        let args = arguments.map(quoted).joined(separator: " ")
        let inner = """
            d=$(/usr/bin/mktemp -d /private/tmp/notchkeeper-firewall-root.XXXXXX) || exit 1
            trap '/bin/rm -rf "$d"' EXIT
            s=\(quoted(script.path))
            [ -f "$s" ] && [ ! -L "$s" ] || { echo "Script is not a regular file, execution aborted" >&2; exit 1; }
            /usr/bin/head -c 1048576 "$s" > "$d/script.sh" || exit 1
            [ "$(/usr/bin/shasum -a 256 "$d/script.sh" | /usr/bin/cut -c 1-64)" = \(quoted(sha256)) ] || { echo "Script was modified after staging, execution aborted" >&2; exit 1; }
            cd /private/tmp && /bin/bash --noprofile --norc "$d/script.sh" \(args)
            """
        return "exec /usr/bin/env -i \(cleanEnvironment) /bin/sh -c " + quoted(inner)
    }

    /// Root command execution does not inherit Pip's environment: prevents attacks injecting `BASH_ENV` or `DYLD_*`.
    private static let cleanEnvironment = "PATH=/usr/bin:/bin:/usr/sbin:/sbin"

    /// Single quote wrapping, escaping embedded single quotes as '\''.
    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Displays system administrator authorization dialog. Arguments passed via argv to AppleScript avoiding string injection;
    /// `without altering line endings`: preserves newline fidelity.
    /// @see https://developer.apple.com/library/archive/technotes/tn2065/_index.html
    private static func privileged(_ command: String, prompt: String) async throws -> Outcome {
        let (status, out, err) = try await run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
            "-e", "end run", command, prompt,
        ])
        if status == 0 { return .done }
        // User cancelled error code -128 (userCanceledErr)
        if err.contains("(-128)") { return .cancelled }
        // Rescue script output in stdout on failure: expose both to user
        throw Failure(errorDescription: [out, err].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// Executes background process, capturing stdout and stderr.
    private static func run(_ path: String, _ args: [String]) async throws -> (Int32, String, String) {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            // Read both pipes concurrently to prevent deadlocks from full buffers
            async let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            let stdout = await o
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
    }
}
