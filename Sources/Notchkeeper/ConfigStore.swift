import AppKit
import Combine
import GuardCore
import NotchCore

/// Answers: How to read and write config.json - loading at startup, persisting on modification, hot-reloading on external edits; retains original file on parse failures without overwriting (CLAUDE.md Principle 5).
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet { if config != oldValue && !applyingExternal { scheduleSave() } }
    }

    let url: URL
    /// File on disk is unreadable or unparseable: do not write to disk in this state to avoid default values overwriting manual edits (CLAUDE.md Principle 5). Cleared when repaired via hot reload.
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
        // Hot reload: directory monitoring catches atomic replacement (most editors), file monitoring catches in-place rewriting. No polling: do not wake up every second when idle.
        // Other file changes in directory also wake it up; returns immediately if modification time unchanged.
        let name = url.lastPathComponent
        directory = WatchedDirectory(url.deletingLastPathComponent(), matching: { $0 == name }, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.fileChanged() }
        }
        if directory?.open() == true {
            watchFile()
        } else {
            log("Configuration directory cannot be opened; external config file modifications will require App restart to load")
        }
    }

    /// Allowlist fetched by guard each round. Discards entries that are not valid IPv4: only present if manually editing config.json, entries added via settings pane are validated and visible in list.
    /// If file fails to parse on startup, `config` defaults to empty allowlist, guard falls back to unknown at most, and settings pane shows a banner; if corrupted while running, previous valid config is retained.
    var allowlistIPs: Set<IPv4> { Set(config.allowlist.compactMap(IPv4.init)) }

    private func fileChanged() {
        watchFile()
        reloadIfChanged()
    }

    /// Re-attach monitoring after file is replaced.
    private func watchFile() {
        do {
            _ = try directory?.list()
        } catch {
            log("Configuration directory cannot be read; external config file modifications will require App restart to load")
        }
    }

    private enum File {
        case missing, unreadable
        case loaded(Config, Data)
    }

    /// Only mutated here.
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
            // In-memory changes while corrupted are not considered "consistent with file": reload when file restored.
            lastData = nil
            log("Configuration file \(Self.problem(error)), using current settings without modifying file")
            return .unreadable
        }
    }

    /// Only names the broken key without its value: value may contain an IP (CLAUDE.md "Never log IPs").
    private static func problem(_ error: Error) -> String {
        let path: [CodingKey]
        switch error as? DecodingError {
        case let .typeMismatch(_, c)?, let .valueNotFound(_, c)?, let .keyNotFound(_, c)?, let .dataCorrupted(c)?:
            path = c.codingPath
        case nil:
            return "cannot be read"
        @unknown default:
            return "cannot be parsed"
        }
        return path.isEmpty ? "is not valid JSON" : "item at \(path.map(\.stringValue).joined(separator: ".")) cannot be decoded"
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
        // Just modified externally and events not delivered yet: read first to avoid overwriting; external edits win, memory and file align.
        if reloadIfChanged() { return }
        guard !fileUnreadable else {
            log("Configuration file cannot be parsed; this change remains in memory only and will be overwritten once the file is fixed")
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
            log("Failed to write configuration: \(error.localizedDescription)")
        }
    }

    /// Returns whether new external content was loaded.
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
        log("Hot-reloaded configuration file")
        return true
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile() { NSWorkspace.shared.open(url) }
}
