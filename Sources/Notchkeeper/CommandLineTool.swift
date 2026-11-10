import Foundation
import GuardCore

/// Answers: Where the CLI tool pipctl is installed, and whether it is in PATH.
/// On every launch, App installs bundled pipctl into `bin/`; terminal plugins and user scripts invoke it;
/// symlink in `~/.local/bin` is created only on user action, leaving pre-existing files untouched.
/// Never modifies `~/.zshrc` or reads PATH (CLAUDE.md hard rule).
enum CommandLineTool {
    static let installed = GuardPaths.directory.appendingPathComponent("bin/pipctl")
    /// Many shell setups include this in PATH by default (XDG user bin).
    static let link = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/pipctl")

    enum LinkState: Equatable {
        case linked, absent
        /// The name already exists as another file or symlink pointing elsewhere.
        case occupied
    }

    /// On App launch: replace with bundled version; if missing, keep previous install.
    static func install() {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "pipctl") else { return }
        do {
            try FileManager.default.replaceItem(at: installed, withCopyOf: bundled)
        } catch {
            Log.write("pipctl: installation failed: \(error.localizedDescription)")
        }
    }

    static func linkState(_ link: URL = link, target: URL = installed) -> LinkState {
        do {
            return try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path ? .linked : .occupied
        } catch {
            // Non-existent, or not a symlink (regular file, directory): check existence.
            var info = stat()
            return lstat(link.path, &info) == 0 ? .occupied : .absent
        }
    }

    static func createLink(_ link: URL = link, target: URL = installed) throws {
        guard linkState(link, target: target) == .absent else { throw occupied(link) }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        Log.write("pipctl: symlinked to ~/.local/bin")
    }

    /// No-op if already absent.
    static func removeLink(_ link: URL = link, target: URL = installed) throws {
        switch linkState(link, target: target) {
        case .absent: return
        case .occupied: throw occupied(link)
        case .linked: try FileManager.default.removeItem(at: link)
        }
        Log.write("pipctl: removed symlink in ~/.local/bin")
    }

    private static func occupied(_ link: URL) -> Failure {
        Failure(errorDescription: String(localized: "\(link.path) is already another file; not overwriting it"))
    }
}
