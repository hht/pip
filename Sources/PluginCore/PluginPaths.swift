import Foundation
import GuardCore

/// Locations for inbox and plugin registrations: shared by App and `pipctl`. Follows Maildir: writes into `tmp/`, renames to `new/` when done, App only reads `new/` to avoid half-written files
/// @see https://cr.yp.to/proto/maildir.html
public enum PluginPaths {
    public static let inbox = GuardPaths.directory.appendingPathComponent("inbox", isDirectory: true)
    public static let tmp = inbox.appendingPathComponent("tmp", isDirectory: true)
    public static let new = inbox.appendingPathComponent("new", isDirectory: true)
    /// `plugins/<id>/manifest.json` registers an external plugin
    public static let plugins = GuardPaths.directory.appendingPathComponent("plugins", isDirectory: true)
    /// Replaced or uninstalled plugin directories are moved here instead of deleted
    public static let backup = GuardPaths.directory.appendingPathComponent("backup/plugins", isDirectory: true)
}
