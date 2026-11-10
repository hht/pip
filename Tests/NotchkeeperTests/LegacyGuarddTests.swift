import Foundation
import Testing
@testable import Notchkeeper

/// Install a legacy guardd sandbox in a temporary directory: LaunchAgent plist, binary, state file, plus pipctl in the same directory (should remain untouched).
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-guardd-\(UUID().uuidString)")
    var files: LegacyGuardd.Files {
        LegacyGuardd.Files(plist: root.appendingPathComponent("LaunchAgents/com.notchkeeper.guardd.plist"),
                           binary: root.appendingPathComponent("bin/guardd"),
                           state: root.appendingPathComponent("guard-state.json"))
    }
    var pipctl: URL { root.appendingPathComponent("bin/pipctl") }

    func install(plist: Bool = true) throws {
        let f = files
        for url in [f.binary, f.state, pipctl] + (plist ? [f.plist] : []) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Fake launchctl: records bootout count; `loadedAfterBootout` determines if it remains loaded after unloading.
private final class FakeLaunchd: @unchecked Sendable {
    var bootouts = 0
    var loadedAfterBootout = false
    var launchd: LegacyGuardd.Launchd {
        LegacyGuardd.Launchd(bootout: { self.bootouts += 1 }, isLoaded: { self.bootouts == 0 || self.loadedAfterBootout }, wait: {})
    }
}

@Suite struct LegacyGuarddTests {
    /// Not installed (no plist): does nothing, does not even invoke launchctl.
    @Test func notInstalledDoesNothing() throws {
        let s = Sandbox()
        try s.install(plist: false)
        let fake = FakeLaunchd()
        LegacyGuardd.remove(s.files, launchd: fake.launchd, log: { _ in })
        #expect(fake.bootouts == 0)
        #expect(s.exists(s.files.binary) && s.exists(s.files.state))
    }

    /// Installed: unloads LaunchAgent first, then deletes plist, binary, and state files; leaves pipctl untouched.
    @Test func removesAgentAndItsFiles() throws {
        let s = Sandbox()
        try s.install()
        let fake = FakeLaunchd()
        var lines: [String] = []
        LegacyGuardd.remove(s.files, launchd: fake.launchd, log: { lines.append($0) })
        #expect(fake.bootouts == 1)
        #expect(!s.exists(s.files.plist) && !s.exists(s.files.binary) && !s.exists(s.files.state))
        #expect(s.exists(s.pipctl))
        #expect(!lines.isEmpty)
    }

    /// Cannot unload (remains in launchd): deletes no files, retries on next launch.
    @Test func keepsFilesWhenAgentWontUnload() throws {
        let s = Sandbox()
        try s.install()
        let fake = FakeLaunchd()
        fake.loadedAfterBootout = true
        LegacyGuardd.remove(s.files, launchd: fake.launchd, log: { _ in })
        #expect(s.exists(s.files.plist) && s.exists(s.files.binary) && s.exists(s.files.state))
    }
}
