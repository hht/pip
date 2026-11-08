import Foundation
import GuardCore

/// Answers: Whether Notchkeeper's bundled Claude Code mod is installed, and how to install/uninstall it (docs/agent-integration.md "Installation & Uninstallation").
/// Copies mod files and runs `claude plugin` commands; never manually edits config files or reads shell configuration.
enum ClaudeMod {
    enum Status: Equatable {
        case installed
        /// Installed, but disabled in Claude Code.
        case disabled
        case notInstalled
        /// No `claude` executable found in standard candidate locations.
        case noClaude
        /// `claude plugin list` failed, with error description.
        case unknown(String)
    }

    private static let pluginID = "notchkeeper@notchkeeper"
    private static let marketplace = "notchkeeper"
    /// Fixed marketplace location: plugin loads in-place from here, resilient to App relocation.
    static let directory = GuardPaths.directory.appendingPathComponent("ClaudeMod", isDirectory: true)
    /// Bundled copy in App bundle; absent when running directly via `swift run`.
    private static var bundled: URL? { Bundle.main.url(forResource: "ClaudeMod", withExtension: nil) }
    /// Inspect only these candidate locations: native install, Homebrew (Apple Silicon, Intel).
    private static let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static var claude: URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Output from `claude plugin list --json`: an array of entries with `id` and `enabled`.
    static func status(fromList data: Data) throws -> Status {
        struct Entry: Decodable {
            var id: String
            var enabled: Bool
        }
        guard let mine = try JSONDecoder().decode([Entry].self, from: data).first(where: { $0.id == pluginID }) else { return .notInstalled }
        return mine.enabled ? .installed : .disabled
    }

    static func status() async -> Status {
        guard let claude else { return .noClaude }
        do {
            return try status(fromList: try await run(claude, ["plugin", "list", "--json"]))
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    static func install() async throws {
        guard let claude else { throw Failure(errorDescription: String(localized: "Can't find claude")) }
        try copyBundled()
        _ = try await run(claude, ["plugin", "install", "notchkeeper", "--marketplace", directory.path, "--json"])
        Log.write("Claude Code mod: installed")
    }

    /// Removing marketplace cascades to uninstall plugin and remove from `enabledPlugins` (<https://code.claude.com/docs/en/plugins/install#manage-marketplaces>).
    static func uninstall() async throws {
        guard let claude else { throw Failure(errorDescription: String(localized: "Can't find claude")) }
        _ = try await run(claude, ["plugin", "marketplace", "remove", marketplace, "--json"])
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Already uninstalled, directory absent.
        }
        Log.write("Claude Code mod: uninstalled")
    }

    /// On App launch: if installed, replace with bundled version so next session picks up changes without version bumps.
    static func refreshIfInstalled() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try copyBundled()
        } catch {
            Log.write("Claude Code mod: update failed: \(error.localizedDescription)")
        }
    }

    /// Plugins load in-place from here: atomic replace keeps previous copy on failure (`replaceItem(at:withCopyOf:)`).
    private static func copyBundled() throws {
        guard let bundled else { throw Failure(errorDescription: String(localized: "This build doesn't include the mod; package it with scripts/run.sh")) }
        try FileManager.default.replaceItem(at: directory, withCopyOf: bundled)
    }

    /// Runs a `claude` command, returns stdout; throws with last output line if exit status != 0.
    /// Kills process and throws timeout on 60s deadline regardless of child process pipes.
    private static func run(_ claude: URL, _ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        // Prevent background auto-updater: child processes inherit pipes preventing EOF.
        process.environment = ProcessInfo.processInfo.environment.merging(["DISABLE_AUTOUPDATER": "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let run = Run(out: out.fileHandleForReading, err: err.fileHandleForReading)
        return try await withCheckedThrowingContinuation { continuation in
            run.start(continuation)
            out.fileHandleForReading.readabilityHandler = { run.append($0.availableData, pipe: 0) }
            err.fileHandleForReading.readabilityHandler = { run.append($0.availableData, pipe: 1) }
            process.terminationHandler = { run.exited($0.terminationStatus) }
            do {
                try process.run()
            } catch {
                run.finish(.failure(error))
                return
            }
            // Force terminate after 60s deadline: handles cases where child processes hold pipes open.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                run.finish(.failure(Failure(errorDescription: String(localized: "Timed out"))))
            }
        }
    }

    /// Single execution outcome: finished only after process exits and both streams hit EOF.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let handles: [FileHandle]
        private var continuation: CheckedContinuation<Data, Error>?
        /// [stdout, stderr]
        private var data = [Data(), Data()]
        private var closed = [false, false]
        private var status: Int32?

        init(out: FileHandle, err: FileHandle) { handles = [out, err] }

        func start(_ c: CheckedContinuation<Data, Error>) {
            lock.withLock { continuation = c }
        }

        /// Empty data signifies EOF: remove handler to prevent repeated invocation.
        func append(_ chunk: Data, pipe: Int) {
            lock.withLock {
                if chunk.isEmpty {
                    closed[pipe] = true
                    handles[pipe].readabilityHandler = nil
                } else {
                    data[pipe] += chunk
                }
            }
            settle()
        }

        func exited(_ code: Int32) {
            lock.withLock { status = code }
            settle()
        }

        private func settle() {
            let result: Result<Data, Error>? = lock.withLock {
                guard let status, !closed.contains(false) else { return nil }
                if status == 0 { return .success(data[0]) }
                let last = String(decoding: data[1] + data[0], as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
                return .failure(Failure(errorDescription: last ?? String(localized: "Exit code \(status)")))
            }
            if let result { finish(result) }
        }

        func finish(_ result: Result<Data, Error>) {
            let c: CheckedContinuation<Data, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let c else { return }
            handles.forEach { $0.readabilityHandler = nil }
            c.resume(with: result)
        }
    }
}
