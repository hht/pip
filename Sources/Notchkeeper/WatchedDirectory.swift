import Darwin
import Foundation

/// Answers: which watched files (default `.json`) currently exist in a directory, and when activity occurs.
/// Attaches a monitor to the directory itself; if `watchesFiles` is true, also monitors each contained file, invoking `onChange` on activity.
/// Does not read file contents. Used solely on the queue provided during initialization (`AgentWatcher`, `InboxWatcher`, `ConfigStore`).
final class WatchedDirectory {
    let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// Filename -> its file system monitor
    private var files: [String: DispatchSourceFileSystemObject] = [:]
    /// Required only when files are rewritten in place (inode unchanged, directory receives no event); not needed for directories that only add, remove, or rename
    private let watchesFiles: Bool
    /// Filter predicate for filenames to monitor
    private let matching: (String) -> Bool

    init(_ url: URL, watchesFiles: Bool = true, matching: @escaping (String) -> Bool = { $0.hasSuffix(".json") },
         queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.url = url
        self.watchesFiles = watchesFiles
        self.matching = matching
        self.queue = queue
        self.onChange = onChange
    }

    /// If directory does not exist, do not watch it; wait until App restarts. Returns whether opened successfully.
    func open() -> Bool {
        source = watch(url, events: [.write, .delete, .rename]) { [weak self] _ in self?.onChange() }
        return source != nil
    }

    /// Lists matching files in directory, attaching monitors to new files and cancelling missing ones.
    /// If directory cannot be read, cancels all monitors before throwing:
    /// monitoring a deleted directory is useless and avoids repeated errors on every event.
    func list() throws -> Set<String> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            source?.cancel()
            source = nil
            files.values.forEach { $0.cancel() }
            files.removeAll()
            throw error
        }
        let jsons = Set(names.filter(matching))
        for name in files.keys where !jsons.contains(name) { files.removeValue(forKey: name)?.cancel() }
        // Attach monitor before reading: captures modifications occurring between read and monitor setup
        for name in jsons where watchesFiles && files[name] == nil {
            files[name] = watch(url.appendingPathComponent(name), events: [.write, .extend, .delete, .rename]) { [weak self] data in
                guard let self else { return }
                if !data.isDisjoint(with: [.delete, .rename]) { files.removeValue(forKey: name)?.cancel() }
                onChange()
            }
        }
        return jsons
    }

    /// `O_EVTONLY`: opens for event monitoring only. Returns nil if cannot open (e.g. file was just deleted)
    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent,
                       handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(fd) }
        source.activate()
        return source
    }
}
