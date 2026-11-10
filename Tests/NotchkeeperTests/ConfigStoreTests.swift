import Foundation
import NotchCore
import Testing
@testable import Notchkeeper

private func tempConfig(_ json: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nk-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    if let json { try Data(json.utf8).write(to: url) }
    return url
}

/// External edit: write content and push modification date forward; hot reload discovers changes via modification date.
private func edit(_ url: URL, _ json: String, minutesLater: Double = 1) throws {
    try Data(json.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(minutesLater * 60)], ofItemAtPath: url.path)
}

/// Tests do not write real logs.
private final class Lines { var all: [String] = [] }
@MainActor private func store(_ url: URL, _ lines: Lines = Lines(), clashVergeInstalled: Bool = true) -> ConfigStore {
    ConfigStore(url: url, clashVergeInstalled: clashVergeInstalled, log: { lines.all.append($0) })
}

/// Egress guard only means something with Clash Verge Rev: without it every route bypasses utun and the first round raises a red card.
/// Decided once, when config.json is first created; an existing file keeps whatever it says.
@MainActor @Suite struct ConfigStoreFirstLaunchGuard {
    @Test(arguments: [true, false])
    func newConfigEnablesGuardOnlyWithClashVerge(_ installed: Bool) throws {
        let url = try tempConfig(nil)
        let store = store(url, clashVergeInstalled: installed)
        #expect(store.config.isEnabled(PluginID.exitGuard) == installed)
        let saved = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        #expect(saved.isEnabled(PluginID.exitGuard) == installed)
    }

    @Test func existingConfigIsNotChanged() throws {
        let url = try tempConfig(#"{"soundEnabled":false}"#)
        let store = store(url, clashVergeInstalled: false)
        #expect(store.config.isEnabled(PluginID.exitGuard))
        #expect(try Data(contentsOf: url) == Data(#"{"soundEnabled":false}"#.utf8))
    }
}

/// CLAUDE.md Principle 5: Degrade gracefully on unparseable external data; never overwrite original file.
@MainActor @Suite struct ConfigStoreKeepsUnreadableFile {
    @Test(arguments: [
        #"{"allowlist":["198.51.100.8"],"#,                      // Syntax error
        #"{"allowlist":"198.51.100.8","soundEnabled":false}"#,   // Wrong field type
    ])
    func startupDoesNotOverwrite(_ json: String) throws {
        let url = try tempConfig(json)
        let store = store(url)
        #expect(store.config == Config())
        #expect(store.fileUnreadable)
        store.config.hoverExpand.toggle()
        store.saveNow()
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }

    @Test func breakingFileWhileRunningDoesNotOverwrite() throws {
        let url = try tempConfig(#"{"allowlist":["198.51.100.8"]}"#)
        let store = store(url)
        let broken = #"{"allowlist":["198.51.100.8","198.51.100.9""#
        try edit(url, broken)
        store.reloadIfChanged()
        #expect(store.config.allowlist == ["198.51.100.8"])
        #expect(store.fileUnreadable)
        store.config.hoverExpand.toggle()
        store.saveNow()
        #expect(try Data(contentsOf: url) == Data(broken.utf8))
    }

    @Test func fixedFileIsLoadedAndSavedAgain() throws {
        let url = try tempConfig("{not json")
        let store = store(url)
        try edit(url, #"{"allowlist":["198.51.100.8"]}"#)
        store.reloadIfChanged()
        #expect(store.config.allowlist == ["198.51.100.8"])
        #expect(!store.fileUnreadable)
        store.config.soundEnabled = false
        store.saveNow()
        #expect(try JSONDecoder().decode(Config.self, from: Data(contentsOf: url)).soundEnabled == false)
    }

    @Test func missingFileIsCreatedWithDefaults() throws {
        let url = try tempConfig(nil)
        _ = store(url)
        #expect(try JSONDecoder().decode(Config.self, from: Data(contentsOf: url)) == Config())
    }

    /// Missing fields fallback to defaults, unknown fields ignored (CLAUDE.md "Configuration & State Files").
    @Test func missingAndUnknownKeysStillLoad() throws {
        let url = try tempConfig(#"{"allowlist":["198.51.100.8"],"future":1}"#)
        var expected = Config()
        expected.allowlist = ["198.51.100.8"]
        #expect(store(url).config == expected)
    }

    /// URL schemes allowlist defaults empty: only https allowed.
    @Test func urlSchemesDefaultEmptyAndLoad() throws {
        #expect(Config().urlSchemes.isEmpty)
        let url = try tempConfig(#"{"urlSchemes":["raycast"]}"#)
        #expect(store(url).config.urlSchemes == ["raycast"])
    }

    /// Restoring file after corruption: in-memory edits during corruption replaced by file contents; UI and guard read same source.
    @Test func restoringOriginalBytesReloadsThem() throws {
        let original = #"{"allowlist":["198.51.100.8"]}"#
        let url = try tempConfig(original)
        let store = store(url)
        try edit(url, "{oops", minutesLater: 1)
        store.reloadIfChanged()
        store.config.allowlist.append("198.51.100.9")
        try edit(url, original, minutesLater: 2)
        store.reloadIfChanged()
        #expect(store.config.allowlist == ["198.51.100.8"])
    }

    /// External edit corrupted just before save and event not yet received: do not overwrite.
    @Test func saveChecksForExternalEditFirst() throws {
        let url = try tempConfig(#"{"allowlist":["198.51.100.8"]}"#)
        let store = store(url)
        let broken = "{oops"
        try edit(url, broken)
        store.config.hoverExpand.toggle()
        store.saveNow()
        #expect(try Data(contentsOf: url) == Data(broken.utf8))
    }

    /// Valid external edit read prior to save: external wins, does not reformat or strip unknown keys from manually edited file.
    @Test func saveYieldsToExternalEdit() throws {
        let url = try tempConfig(#"{"allowlist":["198.51.100.8"]}"#)
        let store = store(url)
        let external = #"{"allowlist":["198.51.100.8","198.51.100.9"],"future":1}"#
        try edit(url, external)
        store.config.soundEnabled = false
        store.saveNow()
        #expect(store.config.allowlist == ["198.51.100.8", "198.51.100.9"])
        #expect(try Data(contentsOf: url) == Data(external.utf8))
    }

    /// Log identifies bad key without exposing values, avoiding IP exposure (CLAUDE.md "Never log IPs").
    @Test func logNamesTheBadKeyWithoutValues() throws {
        let lines = Lines()
        _ = store(try tempConfig(#"{"allowlist":"198.51.100.8"}"#), lines)
        #expect(lines.all.contains { $0.contains("allowlist") })
        #expect(lines.all.allSatisfy { $0.firstMatch(of: /\d+\.\d+\.\d+\.\d+/) == nil })
    }
}

/// External file edit loaded immediately: monitored via directory and file events without polling (CLAUDE.md "Never schedule when invisible").
@MainActor @Suite struct ConfigStoreHotReload {
    /// Catches atomic replacement (most editors) and in-place rewriting (`>`, some editors).
    @Test(arguments: [true, false])
    func externalEditIsLoaded(atomically: Bool) async throws {
        let url = try tempConfig(#"{"soundEnabled":true}"#)
        let store = store(url)
        try Data(#"{"soundEnabled":false}"#.utf8).write(to: url, options: atomically ? .atomic : [])
        for _ in 0..<50 where store.config.soundEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.config.soundEnabled)
    }
}
