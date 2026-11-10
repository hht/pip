import Darwin
import Foundation
import NotchCore
import PluginCore

/// Answers: What external plugins are installed in the plugins directory, how to install/uninstall a plugin folder, and how to create a new empty plugin.
/// File I/O only: manifest validation belongs to `Manifest`, SF Symbol existence verified by caller (requires AppKit). Never executes any files within plugins (CLAUDE.md hard rule "Plugins").
/// Replaced or uninstalled directories moved to `backup`, never deleted: for newly created plugins, directory may contain user's sole script copy
public struct PluginStore: Sendable {
    public enum Problem: Error, Equatable, Sendable {
        /// Folder missing manifest.json
        case noManifest
        case manifest(ManifestError)
        case unknownSymbol(String)
        /// Bundled terminal plugin ID: managed by App, overwritten on launch
        case bundled
        /// Selected directory is already installed destination
        case alreadyInstalled
        case notInstalled
        /// Plugin with same ID already installed on creation
        case exists
    }

    public struct Installed: Sendable {
        public var manifest: Manifest
        /// Where previous version was moved; nil if fresh install
        public var replaced: URL?
    }

    public let plugins: URL
    public let backup: URL

    public init(plugins: URL = PluginPaths.plugins, backup: URL = PluginPaths.backup) {
        self.plugins = plugins
        self.backup = backup
    }

    /// Registered external plugins: `plugins/<id>/manifest.json`. Unreadable entries passed to `onBad` (directory name, nil for root directory; error), considered unregistered
    public func manifests(onBad: (String?, Error) -> Void = { _, _ in }) -> [String: Manifest] {
        let dirs: [String]
        do {
            dirs = try FileManager.default.contentsOfDirectory(atPath: plugins.path)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            onBad(nil, error)
            return [:]
        }
        var result: [String: Manifest] = [:]
        for dir in dirs {
            do {
                let manifest = try Manifest.parse(Self.readRegularFile(plugins.appendingPathComponent(dir).appendingPathComponent("manifest.json")),
                                                  directoryName: dir)
                result[manifest.id] = manifest
            } catch POSIXError.ENOENT, POSIXError.ENOTDIR {
                // Unregistered directory; regular file like .DS_Store
                continue
            } catch {
                onBad(dir, error)
            }
        }
        return result
    }

    /// Inspect manifest in folder to install: for user confirmation, makes no changes. Folder name arbitrary, installed directory named by id
    public func inspect(_ source: URL, symbolExists: (String) -> Bool) throws -> Manifest {
        let data: Data
        do {
            data = try Self.readRegularFile(source.appendingPathComponent("manifest.json"))
        } catch {
            // Selecting file (ENOTDIR) also treated as missing manifest
            guard [.ENOENT, .ENOTDIR].contains(error.code) else { throw error }
            throw Problem.noManifest
        }
        return try Self.checked(data, symbolExists: symbolExists)
    }

    /// Copy to `plugins/<id>/`, source folder untouched. Stages in same-volume temporary directory: failure leaves existing state unchanged.
    /// Symlinks copied as target directory: `copyItem` only copies symlink itself, relative symlinks would break
    public func install(_ source: URL, symbolExists: (String) -> Bool, now: Date) throws -> Installed {
        let source = source.resolvingSymlinksInPath()
        let manifest = try inspect(source, symbolExists: symbolExists)
        let destination = plugins.appendingPathComponent(manifest.id, isDirectory: true)
        guard source.standardizedFileURL.path != destination.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Problem.alreadyInstalled }
        try createPluginsDirectory()
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: plugins, create: true)
        defer {
            // System temporary directory, empty after replacement; ignore errors on cleanup
            do { try fm.removeItem(at: staging) } catch {}
        }
        let copy = staging.appendingPathComponent(manifest.id, isDirectory: true)
        try fm.copyItem(at: source, to: copy)
        // Two renames on same volume: if second fails, old version already safely in backup
        let replaced = try exists(destination) ? moveToBackup(destination, id: manifest.id, now: now) : nil
        try fm.moveItem(at: copy, to: destination)
        return Installed(manifest: manifest, replaced: replaced)
    }

    /// Move to backup, returning destination URL. Bundled terminal plugin managed by App (uninstalled in Settings > Terminal)
    public func uninstall(_ id: String, now: Date) throws -> URL {
        guard id != PluginID.terminal else { throw Problem.bundled }
        let dir = plugins.appendingPathComponent(id, isDirectory: true)
        guard Message.isPluginID(id), try exists(dir) else { throw Problem.notInstalled }
        return try moveToBackup(dir, id: id, now: now)
    }

    /// Create empty plugin with manifest.json only: for authoring personal scripts
    public func create(id: String, name: String, symbol: String, symbolExists: (String) -> Bool) throws -> Manifest {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "symbol": symbol], options: [.prettyPrinted, .sortedKeys])
        } catch {
            preconditionFailure("Strings only")
        }
        let manifest = try Self.checked(data, symbolExists: symbolExists)
        let dir = plugins.appendingPathComponent(id, isDirectory: true)
        guard try !exists(dir) else { throw Problem.exists }
        try createPluginsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    /// Read regular file only, up to `Message.maxBytes + 1` bytes. No symlink follow (`O_NOFOLLOW`), non-blocking (`O_NONBLOCK`):
    /// FIFO in inbox opened blocking would wait indefinitely on writer, hanging queue
    /// @see man 2 open
    public static func readRegularFile(_ url: URL) throws(POSIXError) -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        // read(2) may read partially: read until EOF or upper bound
        var data = Data(count: Message.maxBytes + 1)
        var total = 0
        while total < data.count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, $0.count - total) }
            guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            total += n
        }
        return data.prefix(total)
    }

    private static func checked(_ data: Data, symbolExists: (String) -> Bool) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try Manifest.parse(data, directoryName: nil)
        } catch {
            throw Problem.manifest(error)
        }
        guard manifest.id != PluginID.terminal else { throw Problem.bundled }
        guard symbolExists(manifest.symbol) else { throw Problem.unknownSymbol(manifest.symbol) }
        return manifest
    }

    /// 0700 permissions matching InboxWatcher: prevents other local users from writing
    private func createPluginsDirectory() throws {
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Does not follow symlinks: `plugins/<id>` as symlink also counts as installed
    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return false
        }
        return true
    }

    /// `backup/<id>-<local timestamp>`, appends index if collision within same second
    private func moveToBackup(_ dir: URL, id: String, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let stamp = Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .current)
            .format(now)
        var target = backup.appendingPathComponent("\(id)-\(stamp)", isDirectory: true)
        var n = 2
        while try exists(target) {
            target = backup.appendingPathComponent("\(id)-\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.moveItem(at: dir, to: target)
        return target
    }
}
