import Foundation
import Testing
@testable import Notchkeeper

/// 临时目录里装一份旧的 guardd：LaunchAgent plist、二进制、状态文件，外加同目录的 pipctl（不该被碰）
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

/// 一个假的 launchctl：记下 bootout 了几次，`loadedAfterBootout` 决定卸完还在不在
private final class FakeLaunchd: @unchecked Sendable {
    var bootouts = 0
    var loadedAfterBootout = false
    var launchd: LegacyGuardd.Launchd {
        LegacyGuardd.Launchd(bootout: { self.bootouts += 1 }, isLoaded: { self.bootouts == 0 || self.loadedAfterBootout }, wait: {})
    }
}

@Suite struct LegacyGuarddTests {
    /// 没装过（没有 plist）：什么都不做，连 launchctl 都不调
    @Test func notInstalledDoesNothing() throws {
        let s = Sandbox()
        try s.install(plist: false)
        let fake = FakeLaunchd()
        LegacyGuardd.remove(s.files, launchd: fake.launchd, log: { _ in })
        #expect(fake.bootouts == 0)
        #expect(s.exists(s.files.binary) && s.exists(s.files.state))
    }

    /// 装过：先卸下 LaunchAgent，再删 plist、二进制、状态文件；同目录的 pipctl 不碰
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

    /// 卸不下来（一直还在 launchd 里）：文件一个都不删，下次启动再试
    @Test func keepsFilesWhenAgentWontUnload() throws {
        let s = Sandbox()
        try s.install()
        let fake = FakeLaunchd()
        fake.loadedAfterBootout = true
        LegacyGuardd.remove(s.files, launchd: fake.launchd, log: { _ in })
        #expect(s.exists(s.files.plist) && s.exists(s.files.binary) && s.exists(s.files.state))
    }
}
