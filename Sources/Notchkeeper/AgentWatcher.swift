import AgentCore
import Darwin
import Foundation
import GuardCore

/// Answers: What aggregate agent activity is currently ongoing across Claude Code sessions, and what recent events need user alerts.
/// Handles I/O only: monitors `~/.claude/sessions` and the mod-written `turns/` (docs/agent-integration.md "Two Sources"),
/// reads files, inspects processes, attaches process exit notifications and a scheduled timer;
/// all decisions on whether to observe, what states mean, and how turns end belong to AgentCore (`SessionFile`, `TurnFile`, `AgentBoard`),
/// without duplicating any rules here. Mutable state is only accessed on `queue`, marked `@unchecked Sendable`.
///
/// Three types of notifications trigger a full reread of both directories (only a few sessions, each < 1KB):
/// - Directory `.write`: new session adds a file, normal exit deletes a file.
/// - Individual `.json` file's `.write` / `.extend`: Claude Code rewrites state in-place (same inode, directory gets no event, verified);
///   when file is deleted or renamed (`.delete` / `.rename`), its monitor is closed and reopened based on current directory state during scan.
/// - Process exit notification for each session: after `kill -9`, file remains and directory does not change (docs/agent-integration.md "Empirical" 4).
/// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makefilesystemobjectsource(filedescriptor:eventmask:queue:)
/// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makeprocesssource(identifier:eventmask:queue:)
final class AgentWatcher: @unchecked Sendable {
    struct Update: Sendable {
        var activity: AgentActivity?
        var sessions: [Session]
        var events: [AgentEvent]
    }

    private let onUpdate: @Sendable (Update) -> Void
    private let queue = DispatchQueue(label: "com.notchkeeper.agent-watcher")
    private var board = AgentBoard(since: Date())
    private lazy var sessionFiles = WatchedDirectory(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true),
                                              queue: queue) { [weak self] in self?.scan() }
    private lazy var turnFiles = WatchedDirectory(GuardPaths.directory.appendingPathComponent("turns", isDirectory: true),
                                           queue: queue) { [weak self] in self?.scan() }
    /// Active sessions being monitored: pid -> process exit dispatch source.
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var timer: DispatchSourceTimer?
    private var lastActivity: AgentActivity?
    private var lastSessions: [Session] = []
    /// Unparseable files: log once when first encountered (Principle 5: count and skip, never overwrite original file).
    private var unreadable: Set<URL> = []

    /// Turn files unwritten for this long are remnants from `/clear` or sessions that exited while App was closed. Active sessions will rewrite on turn completion; deleting won't lose alerts.
    private static let staleTurnFile: TimeInterval = 7 * 24 * 3600

    /// `onUpdate` is invoked on internal queue only when activity, session list changes, or events occur.
    init(onUpdate: @escaping @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.publish(events: []) }
            self.timer = timer
            timer.activate()
            if !sessionFiles.open() { Log.write("agent: cannot open sessions directory (errno \(errno)), ignoring agent state") }
            // The turns directory belongs to App: must be created before watching, even if mod hasn't written to it yet.
            do {
                try FileManager.default.createDirectory(at: turnFiles.url, withIntermediateDirectories: true)
                try pruneTurnFiles()
            } catch {
                Log.write("agent: cannot create or read turns directory: \(error.localizedDescription)")
            }
            if !turnFiles.open() { Log.write("agent: cannot open turns directory (errno \(errno)), completed/error cards will not pop up") }
            scan()
        }
    }

    private func pruneTurnFiles() throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for url in try FileManager.default.contentsOfDirectory(at: turnFiles.url, includingPropertiesForKeys: Array(keys))
        where url.pathExtension == "json" {
            guard let modified = try url.resourceValues(forKeys: keys).contentModificationDate,
                  -modified.timeIntervalSinceNow > Self.staleTurnFile else { continue }
            removeTurnFile(url)
        }
    }

    /// Non-existent file (mod not installed or not loaded in this session) is not an error.
    private func removeTurnFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Log.write("agent: cannot delete turn file: \(error.localizedDescription)")
        }
    }

    private func scan() {
        let now = Date()
        var events: [AgentEvent] = []
        let names: Set<String>
        do {
            names = try sessionFiles.list()
        } catch {
            Log.write("agent: failed to read sessions directory, ignoring agent state: \(error.localizedDescription)")
            publish(events: exitSources.keys.compactMap(forget))
            return
        }
        var present: Set<Int32> = []
        for name in names {
            let url = sessionFiles.url.appendingPathComponent(name)
            let session: Session?
            do {
                session = try SessionFile.parse(Data(contentsOf: url))
            } catch CocoaError.fileReadNoSuchFile {
                continue // Normal exit deleted file between directory listing and read
            } catch {
                // If unreadable or unparseable, skip but do not treat as dead: preserve last read state
                if let pid = Int32(name.dropLast(5)) { present.insert(pid) }
                markUnreadable(url, error)
                continue
            }
            unreadable.remove(url)
            guard let session else { continue }
            watchExit(session.pid) // Attach exit watcher before process check: catch exits during the interval
            guard Self.isRunning(pid: session.pid, since: session.processStart) else { continue }
            present.insert(session.pid)
            if let event = board.update(session, at: now) { events.append(event) }
        }
        events += exitSources.keys.filter { !present.contains($0) }.compactMap(forget)
        // Sessions precede turn files: newly discovered session matches its turn file
        do {
            for name in try turnFiles.list() {
                let url = turnFiles.url.appendingPathComponent(name)
                do {
                    let report = try TurnFile.parse(Data(contentsOf: url))
                    unreadable.remove(url)
                    if let event = board.update(report, at: now) { events.append(event) }
                } catch CocoaError.fileReadNoSuchFile {
                    continue
                } catch {
                    markUnreadable(url, error)
                }
            }
        } catch {
            Log.write("agent: failed to read turns directory, completed/error cards will not pop up: \(error.localizedDescription)")
        }
        publish(events: events)
    }

    private func markUnreadable(_ url: URL, _ error: Error) {
        if unreadable.insert(url).inserted {
            Log.write("agent: unreadable file in \(url.deletingLastPathComponent().lastPathComponent), skipped (\(unreadable.count) unreadable): \(error)")
        }
    }
    /// Process is alive and start time matches `procStart` in file (guards against PID reuse). Inability to query implies process is not running.
    /// @see https://opensource.apple.com/source/xnu/xnu-7195.81.3/bsd/sys/proc_info.h (`proc_bsdinfo.pbi_start_tvsec`)
    static func isRunning(pid: Int32, since processStart: Date) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return TimeInterval(info.pbi_start_tvsec) == processStart.timeIntervalSince1970
    }

    private func watchExit(_ pid: Int32) {
        guard exitSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.publish(events: [self.forget(pid)].compactMap { $0 })
        }
        exitSources[pid] = source
        source.activate()
    }

    /// Stop observing process and delete its turn file (mod won't write again); returns intervention ended if currently awaiting user input.
    private func forget(_ pid: Int32) -> AgentEvent? {
        exitSources.removeValue(forKey: pid)?.cancel()
        if let session = board.sessions.first(where: { $0.pid == pid }) {
            removeTurnFile(turnFiles.url.appendingPathComponent(session.sessionId + ".json"))
        }
        return board.remove(pid: pid)
    }

    private func publish(events: [AgentEvent]) {
        let now = Date()
        let activity = board.activity(at: now)
        if let next = board.nextChange(after: now) {
            timer?.schedule(wallDeadline: .now() + next.timeIntervalSince(now), leeway: .milliseconds(10))
        }
        let sessions = board.sessions
        guard activity != lastActivity || sessions != lastSessions || !events.isEmpty else { return }
        lastActivity = activity
        lastSessions = sessions
        onUpdate(Update(activity: activity, sessions: sessions, events: events))
    }
}
