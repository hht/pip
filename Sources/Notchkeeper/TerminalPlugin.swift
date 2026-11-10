import Foundation
import PluginCore

/// Answers: Whether Notchkeeper's bundled terminal plugin is installed, and how to install/uninstall it.
/// File copy only: copies zsh script and manifest into `plugins/terminal/`; script invokes App's installed `bin/pipctl` (`CommandLineTool`).
/// `plugins/terminal/` is managed by App: replaced entirely with new version on each launch, other files placed inside will be removed.
/// Never modifies `~/.zshrc` or reads shell configurations (CLAUDE.md hard rule): the `source` line is added by the user manually.
enum TerminalPlugin {
    static let directory = PluginPaths.plugins.appendingPathComponent("terminal", isDirectory: true)
    private static let script = directory.appendingPathComponent("pip.zsh")

    /// The line user adds to `~/.zshrc`: uses `$HOME`, valid across machines and usernames; if user forgets to remove after uninstalling, new shells won't error.
    static var sourceLine: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = script.path.hasPrefix(home + "/") ? "$HOME" + script.path.dropFirst(home.count) : script.path
        return "[[ -r \"\(path)\" ]] && source \"\(path)\""
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: script.path) }

    static func install() throws {
        // Not present in App bundle when running directly via `swift run`.
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("plugins/terminal", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.path)
        else { throw Failure(errorDescription: String(localized: "This build doesn't include the terminal plugin; package it with scripts/run.sh")) }
        try FileManager.default.replaceItem(at: directory, withCopyOf: bundled)
        Log.write("Terminal plugin: installed")
    }

    static func uninstall() throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Already uninstalled.
        }
        Log.write("Terminal plugin: uninstalled")
    }

    /// On App launch: if installed, replace with bundled version so new terminals pick up updates.
    static func refreshIfInstalled() {
        guard isInstalled else { return }
        do {
            try install()
        } catch {
            Log.write("Terminal plugin: update failed: \(error.localizedDescription)")
        }
    }
}
