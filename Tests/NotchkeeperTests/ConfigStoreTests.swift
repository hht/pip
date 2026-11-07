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

/// 外部改了文件：换内容并把修改时间往后拨，热加载靠修改时间发现变化
private func edit(_ url: URL, _ json: String, minutesLater: Double = 1) throws {
    try Data(json.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(minutesLater * 60)], ofItemAtPath: url.path)
}

/// 测试不写真实日志
private final class Lines { var all: [String] = [] }
@MainActor private func store(_ url: URL, _ lines: Lines = Lines()) -> ConfigStore {
    ConfigStore(url: url, log: { lines.all.append($0) })
}

/// CLAUDE.md 准则 5：解析不了的外部数据降级，不覆盖原文件
@MainActor @Suite struct ConfigStoreKeepsUnreadableFile {
    @Test(arguments: [
        #"{"allowlist":["198.51.100.8"],"#,                      // 语法错误
        #"{"allowlist":"198.51.100.8","soundEnabled":false}"#,   // 字段类型不对
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

    /// 缺失字段用默认值、未知字段忽略（CLAUDE.md「配置与状态文件」）
    @Test func missingAndUnknownKeysStillLoad() throws {
        let url = try tempConfig(#"{"allowlist":["198.51.100.8"],"future":1}"#)
        var expected = Config()
        expected.allowlist = ["198.51.100.8"]
        #expect(store(url).config == expected)
    }

    /// URL 白名单默认是空的：只放行 https
    @Test func urlSchemesDefaultEmptyAndLoad() throws {
        #expect(Config().urlSchemes.isEmpty)
        let url = try tempConfig(#"{"urlSchemes":["raycast"]}"#)
        #expect(store(url).config.urlSchemes == ["raycast"])
    }

    /// 改坏后又原样改回：坏着时在内存里的改动要被文件内容取代，界面和守卫读的是同一份
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

    /// 外部刚改坏、监听的事件还没送到时存盘：也不能覆盖
    @Test func saveChecksForExternalEditFirst() throws {
        let url = try tempConfig(#"{"allowlist":["198.51.100.8"]}"#)
        let store = store(url)
        let broken = "{oops"
        try edit(url, broken)
        store.config.hoverExpand.toggle()
        store.saveNow()
        #expect(try Data(contentsOf: url) == Data(broken.utf8))
    }

    /// 存盘前读到了外部的合法改动：外部的赢，也不把手写的文件重排格式、去掉未知键
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

    /// 日志指出是哪个键坏了，但不带值，也就不会带出 IP（CLAUDE.md「日志不记 IP」）
    @Test func logNamesTheBadKeyWithoutValues() throws {
        let lines = Lines()
        _ = store(try tempConfig(#"{"allowlist":"198.51.100.8"}"#), lines)
        #expect(lines.all.contains { $0.contains("allowlist") })
        #expect(lines.all.allSatisfy { $0.firstMatch(of: /\d+\.\d+\.\d+\.\d+/) == nil })
    }
}

/// 外部改了文件马上载入：靠监听目录和文件，不轮询（CLAUDE.md「看不见就不调度」）
@MainActor @Suite struct ConfigStoreHotReload {
    /// 原子替换（大多数编辑器）和原地改写（`>`、部分编辑器）都要收得到
    @Test(arguments: [true, false])
    func externalEditIsLoaded(atomically: Bool) async throws {
        let url = try tempConfig(#"{"soundEnabled":true}"#)
        let store = store(url)
        try Data(#"{"soundEnabled":false}"#.utf8).write(to: url, options: atomically ? .atomic : [])
        for _ in 0..<50 where store.config.soundEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.config.soundEnabled)
    }
}
