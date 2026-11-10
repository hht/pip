import Foundation
import GuardCore

/// Answers: How to remove the legacy standalone guard background process guardd (user-level LaunchAgent).
/// After Egress Guard was integrated into the App, guardd became obsolete. Keeping it would probe the network every 5s.
/// On each App launch, check: if the plist exists, unload the LaunchAgent. Only after unloading, delete the plist,
/// binary, and state files. If unload fails, delete nothing and retry on next launch. Logs and install backups are kept.
/// No sudo required: LaunchAgent lives in the current user's `gui/<uid>` domain.
/// Once all machines running guardd have launched the new version at least once, this file can be removed.
/// @see https://keith.github.io/xcode-man-pages/launchctl.1.html (bootout, print)
enum LegacyGuardd {
    static let label = "com.notchkeeper.guardd"

    struct Files {
        var plist: URL
        var binary: URL
        var state: URL

        static let live = Files(
            plist: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist"),
            binary: GuardPaths.directory.appendingPathComponent("bin/guardd"),
            state: GuardPaths.directory.appendingPathComponent("guard-state.json"))
    }

    /// Two launchctl actions, replaced with fakes in tests.
    struct Launchd {
        var bootout: () -> Void
        var isLoaded: () -> Bool
        /// Wait briefly between two queries.
        var wait: () -> Void

        static let live = Launchd(
            bootout: { _ = launchctl("bootout", "\(domain)/\(label)") },
            isLoaded: { launchctl("print", "\(domain)/\(label)") == 0 },
            wait: { Thread.sleep(forTimeInterval: 1) })

        private static var domain: String { "gui/\(getuid())" }

        /// Exit code; return -1 if unable to run. Discard output: print dumps the entire job description.
        private static func launchctl(_ args: String...) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
    }

    /// Waits for launchctl; do not call on the main thread.
    static func remove(_ files: Files = .live, launchd: Launchd = .live, log: (String) -> Void = Log.write) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: files.plist.path) else { return }
        if launchd.isLoaded() {
            launchd.bootout()
            // guardd exits at the end of the current round upon receiving SIGTERM; wait up to one round's deadline.
            var waits = 0
            while launchd.isLoaded(), waits < 10 {
                launchd.wait()
                waits += 1
            }
            guard !launchd.isLoaded() else {
                return log("Legacy guard daemon (guardd) could not be unloaded, will retry next launch; files were not deleted")
            }
        }
        for url in [files.plist, files.binary, files.state] {
            do {
                try fm.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already deleted.
            } catch {
                log("Failed to delete legacy guard file \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        log("Egress Guard integrated into App: unloaded legacy guardd background process")
    }
}
