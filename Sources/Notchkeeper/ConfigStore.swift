import AppKit
import Combine
import GuardCore
import NotchCore

/// 回答：config.json 怎么读写——启动载入、改了存盘、外部改了热加载；文件解不开时不写盘，保留原文件（CLAUDE.md 准则 5）
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet { if config != oldValue && !applyingExternal { scheduleSave() } }
    }

    let url: URL
    /// 磁盘上的文件读不了或解不开：这时不写盘，免得默认值盖掉手改的内容（CLAUDE.md 准则 5）。改好后热加载会清掉它
    @Published private(set) var fileUnreadable = false
    private let log: (String) -> Void
    private var applyingExternal = false
    private var lastData: Data?
    private var lastMTime: Date?
    private var saveWork: DispatchWorkItem?
    private var directory: WatchedDirectory?

    init(url: URL = GuardPaths.configFile, log: @escaping (String) -> Void = Log.write) {
        self.url = url
        self.log = log
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        config = Config()
        switch read() {
        case .missing:
            saveNow()
        case .unreadable:
            break
        case let .loaded(c, data):
            config = c
            lastData = data
        }
        lastMTime = mtime()
        // 热加载：目录的监听收原子替换（大多数编辑器），文件的监听收原地改写。不轮询：没人改时不该每秒醒一次。
        // 目录里别的文件变了也会叫醒它，比一次修改时间就回去
        let name = url.lastPathComponent
        directory = WatchedDirectory(url.deletingLastPathComponent(), matching: { $0 == name }, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.fileChanged() }
        }
        if directory?.open() == true {
            watchFile()
        } else {
            log("配置目录打不开，外部改了配置文件要重启 App 才载入")
        }
    }

    /// 守卫每轮取的允许列表。不是合法 IPv4 的条目丢掉：只有手改 config.json 才会有，设置页加的都校验过、列表里也看得见它们。
    /// 启动时文件就解不开，`config` 是默认值（空列表），守卫最多判到 unknown，设置页有横幅；运行中改坏了沿用改坏前的
    var allowlistIPs: Set<IPv4> { Set(config.allowlist.compactMap(IPv4.init)) }

    private func fileChanged() {
        watchFile()
        reloadIfChanged()
    }

    /// 文件被替换后要重新挂上监听
    private func watchFile() {
        do {
            _ = try directory?.list()
        } catch {
            log("配置目录读不了，外部改了配置文件要重启 App 才载入")
        }
    }

    private enum File {
        case missing, unreadable
        case loaded(Config, Data)
    }

    /// 只有这里写 `fileUnreadable`
    private func read() -> File {
        do {
            let data = try Data(contentsOf: url)
            let file = File.loaded(try JSONDecoder().decode(Config.self, from: data), data)
            fileUnreadable = false
            return file
        } catch CocoaError.fileReadNoSuchFile {
            fileUnreadable = false
            return .missing
        } catch {
            fileUnreadable = true
            // 坏着时内存里的改动不算「和文件一致」：文件原样改回时也要重新载入
            lastData = nil
            log("配置文件\(Self.problem(error))，先用当前设置，不改文件")
            return .unreadable
        }
    }

    /// 只说哪个键坏了，不带值：值里可能有 IP（CLAUDE.md「日志不记 IP」）
    private static func problem(_ error: Error) -> String {
        let path: [CodingKey]
        switch error as? DecodingError {
        case let .typeMismatch(_, c)?, let .valueNotFound(_, c)?, let .keyNotFound(_, c)?, let .dataCorrupted(c)?:
            path = c.codingPath
        case nil:
            return "读不了"
        @unknown default:
            return "解不开"
        }
        return path.isEmpty ? "不是合法的 JSON" : "里 \(path.map(\.stringValue).joined(separator: ".")) 这一项解不开"
    }

    private func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func saveNow() {
        // 外部刚改过、监听的事件还没送到：先读进来，免得盖掉；读进来了就是外部的赢，内存和文件已经一致
        if reloadIfChanged() { return }
        guard !fileUnreadable else {
            log("配置文件解不开，这次改动只在内存里，改好文件后会被文件内容取代")
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config), data != lastData else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastData = data
            lastMTime = mtime()
        } catch {
            log("配置写入失败：\(error.localizedDescription)")
        }
    }

    /// 返回是否载入了外部的新内容
    @discardableResult
    func reloadIfChanged() -> Bool {
        let m = mtime()
        guard m != lastMTime else { return false }
        lastMTime = m
        guard case let .loaded(c, data) = read(), data != lastData else { return false }
        lastData = data
        guard c != config else { return true }
        applyingExternal = true
        config = c
        applyingExternal = false
        log("已热加载配置文件")
        return true
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile() { NSWorkspace.shared.open(url) }
}
