import Darwin
import Foundation
import Testing
@testable import PluginCore
@testable import PluginStore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let knownSymbols: @Sendable (String) -> Bool = { ["star", "terminal", "hammer"].contains($0) }

/// Temporary directory holding `plugins/`, `backup/`, and plugin folder `source/<name>/`
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-store-\(UUID().uuidString)")
    var plugins: URL { root.appendingPathComponent("plugins") }
    var backup: URL { root.appendingPathComponent("backup") }
    var store: PluginStore { PluginStore(plugins: plugins, backup: backup) }

    /// Plugin folder: manifest.json (omitted if nil) plus a script
    func source(_ manifest: String?, folder: String = "my-plugin", script: String = "echo 1") throws -> URL {
        let dir = root.appendingPathComponent("source/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json")) }
        try Data(script.utf8).write(to: dir.appendingPathComponent("run.sh"))
        return dir
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backup.path).sorted()
    }
}

private let ci = #"{"id":"ci","name":"CI","symbol":"hammer"}"#

@Suite struct PluginStoreInspect {
    @Test func valid() throws {
        let s = try Sandbox()
        // Folder name arbitrary: installed directory named by id
        let m = try s.store.inspect(s.source(ci, folder: "ci-plugin-v2"), symbolExists: knownSymbols)
        #expect(m == Manifest(id: "ci", name: "CI", symbol: "hammer"))
    }

    @Test func rejections() throws {
        let s = try Sandbox()
        func reason(_ manifest: String?) throws -> PluginStore.Problem? {
            do {
                _ = try s.store.inspect(s.source(manifest, folder: UUID().uuidString), symbolExists: knownSymbols)
                return nil
            } catch let error as PluginStore.Problem {
                return error
            }
        }
        #expect(try reason(nil) == .noManifest)
        #expect(try reason("not JSON") == .manifest(.malformed))
        #expect(try reason(#"{"id":"guard","name":"x","symbol":"star"}"#) == .manifest(.reservedID))
        #expect(try reason(#"{"id":"Bad","name":"x","symbol":"star"}"#) == .manifest(.badID))
        #expect(try reason(#"{"id":"x","name":"x","symbol":"no.such.symbol"}"#) == .unknownSymbol("no.such.symbol"))
        // Managed by App, overwritten on launch
        #expect(try reason(#"{"id":"terminal","name":"x","symbol":"star"}"#) == .bundled)
    }
}

@Suite struct PluginStoreInstall {
    @Test func freshInstallCopies() throws {
        let s = try Sandbox()
        let source = try s.source(ci)
        let result = try s.store.install(source, symbolExists: knownSymbols, now: t0)
        #expect(result.manifest.id == "ci" && result.replaced == nil)
        #expect(try s.read("plugins/ci/run.sh") == "echo 1")
        // Original source untouched
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("run.sh").path))
        #expect(s.store.manifests().keys.sorted() == ["ci"])
    }

    /// Re-installing same id is upgrade: old version moved to backup, never deleted
    @Test func upgradeBacksUpOld() throws {
        let s = try Sandbox()
        _ = try s.store.install(s.source(ci, folder: "v1", script: "v1"), symbolExists: knownSymbols, now: t0)
        let result = try s.store.install(s.source(ci, folder: "v2", script: "v2"), symbolExists: knownSymbols, now: t0.addingTimeInterval(60))
        #expect(try s.read("plugins/ci/run.sh") == "v2")
        let backup = try #require(result.replaced)
        #expect(try String(contentsOf: backup.appendingPathComponent("run.sh"), encoding: .utf8) == "v1")
        #expect(try s.backups().count == 1)
    }

    /// Selected directory is already installed folder: cannot replace itself
    @Test func installedFolderRejected() throws {
        let s = try Sandbox()
        _ = try s.store.install(s.source(ci), symbolExists: knownSymbols, now: t0)
        #expect(throws: PluginStore.Problem.alreadyInstalled) {
            try s.store.install(s.plugins.appendingPathComponent("ci"), symbolExists: knownSymbols, now: t0)
        }
        #expect(try s.read("plugins/ci/run.sh") == "echo 1")
    }

    /// manifest.json as symlink or FIFO: no follow, no wait, report error
    @Test(arguments: [false, true])
    func manifestMustBeRegularFile(_ fifo: Bool) throws {
        let s = try Sandbox()
        let source = try s.source(nil)
        let manifest = source.appendingPathComponent("manifest.json")
        if fifo {
            #expect(mkfifo(manifest.path, 0o600) == 0)
        } else {
            let real = s.root.appendingPathComponent("real.json")
            try Data(ci.utf8).write(to: real)
            try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: real)
        }
        #expect(throws: POSIXError.self) { try s.store.install(source, symbolExists: knownSymbols, now: t0) }
        #expect(s.store.manifests().isEmpty)
    }

    /// Source is subdirectory inside installed plugin (same id): copy out before replace, backup preserves full old version
    @Test func sourceInsideInstalledCopy() throws {
        let s = try Sandbox()
        _ = try s.store.install(s.source(ci, script: "v1"), symbolExists: knownSymbols, now: t0)
        let inner = s.plugins.appendingPathComponent("ci/v2")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(ci.utf8).write(to: inner.appendingPathComponent("manifest.json"))
        try Data("v2".utf8).write(to: inner.appendingPathComponent("run.sh"))
        let result = try s.store.install(inner, symbolExists: knownSymbols, now: t0)
        #expect(try s.read("plugins/ci/run.sh") == "v2")
        let backup = try #require(result.replaced)
        #expect(try String(contentsOf: backup.appendingPathComponent("run.sh"), encoding: .utf8) == "v1")
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("v2/run.sh").path))
    }

    @Test func invalidLeavesNothing() throws {
        let s = try Sandbox()
        #expect(throws: PluginStore.Problem.noManifest) { try s.store.install(s.source(nil), symbolExists: knownSymbols, now: t0) }
        #expect(s.store.manifests().isEmpty)
    }

    /// Symlinked source (relative path): copies directory contents, not symlink itself; survives source removal
    @Test func symlinkedSourceCopiesContents() throws {
        let s = try Sandbox()
        let real = try s.source(ci)
        let link = real.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.lastPathComponent)
        _ = try s.store.install(link, symbolExists: knownSymbols, now: t0)
        try FileManager.default.removeItem(at: real)
        #expect(try s.read("plugins/ci/run.sh") == "echo 1")
        #expect(s.store.manifests().keys.sorted() == ["ci"])
    }

    /// Dragging a file (e.g. .zip): reports no manifest
    @Test func fileSourceHasNoManifest() throws {
        let s = try Sandbox()
        let file = s.root.appendingPathComponent("plugin.zip")
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        try Data("PK".utf8).write(to: file)
        #expect(throws: PluginStore.Problem.noManifest) { try s.store.install(file, symbolExists: knownSymbols, now: t0) }
    }
}

@Suite struct PluginStoreUninstall {
    /// Uninstall moves to backup: preserves user's only copy of custom scripts
    @Test func movesToBackup() throws {
        let s = try Sandbox()
        _ = try s.store.install(s.source(ci), symbolExists: knownSymbols, now: t0)
        let backup = try s.store.uninstall("ci", now: t0)
        #expect(s.store.manifests().isEmpty)
        #expect(try String(contentsOf: backup.appendingPathComponent("run.sh"), encoding: .utf8) == "echo 1")
    }

    /// Multiple installs/uninstalls in same second: unique backup names
    @Test func backupsDoNotCollide() throws {
        let s = try Sandbox()
        for _ in 0..<2 {
            _ = try s.store.install(s.source(ci, folder: UUID().uuidString), symbolExists: knownSymbols, now: t0)
            _ = try s.store.uninstall("ci", now: t0)
        }
        #expect(try s.backups().count == 2)
    }

    /// Bundled terminal plugin managed by App: CLI cannot uninstall it, configure in Settings > Terminal
    @Test func bundledRefused() throws {
        let s = try Sandbox()
        try FileManager.default.createDirectory(at: s.plugins.appendingPathComponent("terminal"), withIntermediateDirectories: true)
        #expect(throws: PluginStore.Problem.bundled) { try s.store.uninstall("terminal", now: t0) }
        #expect(FileManager.default.fileExists(atPath: s.plugins.appendingPathComponent("terminal").path))
    }

    @Test(arguments: ["nope", "guard", "../x", ""])
    func unknownRejected(_ id: String) throws {
        let s = try Sandbox()
        #expect(throws: PluginStore.Problem.notInstalled) { try s.store.uninstall(id, now: t0) }
    }
}

@Suite struct PluginStoreCreate {
    @Test func createsManifestOnly() throws {
        let s = try Sandbox()
        let m = try s.store.create(id: "backup", name: "Backup", symbol: "star", symbolExists: knownSymbols)
        #expect(m == Manifest(id: "backup", name: "Backup", symbol: "star"))
        #expect(s.store.manifests() == ["backup": m])
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.plugins.appendingPathComponent("backup").path) == ["manifest.json"])
    }

    @Test func rejections() throws {
        let s = try Sandbox()
        _ = try s.store.create(id: "backup", name: "Backup", symbol: "star", symbolExists: knownSymbols)
        #expect(throws: PluginStore.Problem.exists) { try s.store.create(id: "backup", name: "x", symbol: "star", symbolExists: knownSymbols) }
        #expect(throws: PluginStore.Problem.manifest(.badID)) { try s.store.create(id: "Backup2", name: "x", symbol: "star", symbolExists: knownSymbols) }
        #expect(throws: PluginStore.Problem.manifest(.missingField)) { try s.store.create(id: "b", name: " ", symbol: "star", symbolExists: knownSymbols) }
        #expect(throws: PluginStore.Problem.unknownSymbol("nope")) { try s.store.create(id: "b", name: "x", symbol: "nope", symbolExists: knownSymbols) }
        #expect(throws: PluginStore.Problem.bundled) { try s.store.create(id: "terminal", name: "x", symbol: "star", symbolExists: knownSymbols) }
    }
}

/// Manifest reading: from InboxWatcher, `plugins/<id>/manifest.json`, rejects mismatched directory names
@Suite struct PluginStoreManifests {
    @Test func mismatchedDirectoryIgnored() throws {
        let s = try Sandbox()
        let dir = s.plugins.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(ci.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        var bad: [String] = []
        #expect(s.store.manifests { d, _ in bad.append(d ?? "") }.isEmpty)
        #expect(bad == ["other"])
    }

    /// Finder creates .DS_Store in visited folders: not a plugin, not reported as broken manifest
    @Test func plainFilesIgnored() throws {
        let s = try Sandbox()
        try FileManager.default.createDirectory(at: s.plugins, withIntermediateDirectories: true)
        try Data().write(to: s.plugins.appendingPathComponent(".DS_Store"))
        var bad: [String?] = []
        #expect(s.store.manifests { d, _ in bad.append(d) }.isEmpty)
        #expect(bad.isEmpty)
    }

    @Test func missingDirectoryIsEmpty() throws {
        #expect(try Sandbox().store.manifests().isEmpty)
    }
}
