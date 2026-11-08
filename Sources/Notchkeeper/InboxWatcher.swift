import AppKit
import Darwin
import PluginCore
import PluginStore

/// Answers: Which external plugin cards and activities have arrived in the inbox.
/// Handles I/O only: creates directories (0700, inaccessible to other users), monitors `inbox/new/`, reads and deletes immediately, reads plugin manifests;
/// parsing, admission, and card creation belong entirely to PluginCore (`Message`, `Manifest`, `InboxGate`). Mutable state is read/written on `queue` only, marked `@unchecked Sendable`.
/// Messages are external data: logs record only drop reasons (PluginCore enum, errno) and counts, never message content or filenames (CLAUDE.md Principle 5).
final class InboxWatcher: @unchecked Sendable {
    /// Items admitted in a single scan: cards, activities, and current plugin registrations.
    struct Batch: Sendable {
        var cards: [InboxGate.Admitted] = []
        var activities: [ActivityUpdate] = []
        var plugins: [String: Manifest]
    }

    private let onBatch: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "com.notchkeeper.inbox")
    private var gate = InboxGate()
    /// Watches directory only: following Maildir semantics, files are renamed in and never modified in-place.
    private lazy var inbox = WatchedDirectory(PluginPaths.new, watchesFiles: false, queue: queue) { [weak self] in self?.scan() }
    private var dropped = 0
    /// Files that could not be deleted: do not reread to prevent popping up on every event.
    private var stuck: Set<String> = []
    /// Unparseable manifest files: logged once on first failure.
    private var badManifests: Set<String> = []

    /// Files in `tmp/` older than this were abandoned midway (following Maildir).
    private static let staleTmp: TimeInterval = 36 * 3600

    /// `onBatch` called on internal queue only when cards or activities are admitted.
    init(onBatch: @escaping @Sendable (Batch) -> Void) {
        self.onBatch = onBatch
    }

    func start() {
        queue.async { [self] in
            do {
                for dir in [PluginPaths.inbox, PluginPaths.tmp, PluginPaths.new, PluginPaths.plugins] {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                }
            } catch {
                Log.write("plugin: cannot create inbox directory (\(Self.code(error))), will not receive external plugin cards")
                return
            }
            pruneTmp()
            guard inbox.open() else {
                Log.write("plugin: cannot open inbox (errno \(errno)), will not receive external plugin cards")
                return
            }
            scan()
        }
    }

    /// Inability to prune does not affect receiving cards: log line and retry next launch.
    private func pruneTmp() {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: PluginPaths.tmp.path)
        } catch {
            Log.write("plugin: cannot read inbox tmp/ (\(Self.code(error))), skipping cleanup")
            return
        }
        for name in names {
            let url = PluginPaths.tmp.appendingPathComponent(name)
            // Do not follow symlinks; files just renamed by pipctl will not be found, skip.
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  -Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)).timeIntervalSinceNow > Self.staleTmp else { continue }
            remove(url)
        }
    }

    private func scan() {
        let names: Set<String>
        do {
            names = try inbox.list()
        } catch {
            Log.write("plugin: failed to read inbox (\(Self.code(error))), will not receive external plugin cards")
            return
        }
        var messages: [Message] = []
        for name in names.subtracting(stuck) {
            let url = inbox.url.appendingPathComponent(name)
            let data: Data
            do {
                data = try PluginStore.readRegularFile(url)
            } catch POSIXError.ENOENT {
                continue
            } catch {
                drop("unreadable (errno \(error.code.rawValue))")
                remove(url)
                continue
            }
            remove(url)
            guard data.count <= Message.maxBytes else {
                drop("too large")
                continue
            }
            do {
                messages.append(try Message.parse(data))
            } catch {
                drop("cannot parse (\(error))")
            }
        }
        guard !messages.isEmpty else { return }
        // Read on demand when messages arrive (only a few plugins); install/uninstall requires no App restart.
        let plugins = Self.manifests { dir, error in
            if badManifests.insert(dir).inserted { Log.write("plugin: manifest.json for \(Self.safe(dir)) is unreadable or invalid (\(error)), treated as unregistered") }
        }
        badManifests.subtract(plugins.keys) // Restored plugins: log again if corrupted later.
        let now = Date()
        var batch = Batch(plugins: plugins)
        for m in messages.sorted(by: { $0.at < $1.at }) {
            do {
                if m.activity == nil {
                    batch.cards.append(try gate.admit(m, plugins: plugins, now: now))
                } else {
                    batch.activities.append(try gate.admitActivity(m, plugins: plugins, now: now))
                }
            } catch .unregistered {
                drop("plugin \(m.plugin) not registered") // ID validated by format, safe to log.
            } catch {
                drop("plugin \(m.plugin): \(error)")
            }
        }
        if !batch.cards.isEmpty || !batch.activities.isEmpty { onBatch(batch) }
    }

    /// Registered external plugins. Unreadable manifests passed to `onBad` and treated as unregistered; settings pane also lists plugins with this.
    /// Missing system symbol replaced with puzzle piece: cards received normally without blank icon area.
    static func manifests(onBad: (String, Error) -> Void = { _, _ in }) -> [String: Manifest] {
        PluginStore().manifests { dir, error in
            guard let dir else { return Log.write("plugin: cannot read plugin directory (\(code(error))), treated as unregistered") }
            onBad(dir, error)
        }.mapValues { m in
            guard !symbolExists(m.symbol) else { return m }
            var fixed = m
            fixed.symbol = "puzzlepiece.extension"
            return fixed
        }
    }

    /// Create new NSImage each time, never shared across threads: Apple permits creation on background threads (Thread Safety Summary "NSImage Restrictions").
    /// @see https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html
    @Sendable static func symbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Directory name is external input: retain letters, digits, hyphens only, truncate before logging.
    private static func safe(_ dir: String) -> String {
        String(String.UnicodeScalarView(dir.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }).prefix(32))
    }

    private func drop(_ why: String) {
        dropped += 1
        Log.write("plugin: dropped message, \(why) (\(dropped) dropped total)")
    }

    /// Delete only this item: deletes symlink itself if symlink.
    private func remove(_ url: URL) {
        guard unlink(url.path) != 0, errno != ENOENT else { return }
        stuck.insert(url.lastPathComponent)
        Log.write("plugin: cannot delete file in inbox (errno \(errno)), ignoring it")
    }

    /// Error code only: Foundation error description contains paths, which could include externally authored filenames.
    private static func code(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }
}
