import Darwin
import Foundation
import FirewallCore

/// Where things are installed, and what they are named. Matches scripts/firewall-rescue.sh, install-firewall.sh, firewall-drill.sh
/// (including AtomicFile temporary file names); if changing, update all four places together.
enum FirewallPaths {
    static let label = "com.notchkeeper.firewall"
    static let anchor = "com.apple/300.Notchkeeper"
    /// root 0755: non-root user processes cannot write files here, preventing forgery of state and status summary (docs/firewall.md §4)
    static let directory = URL(fileURLWithPath: "/Library/Application Support/Notchkeeper")
    /// Mutual exclusion between rounds and commands. root 0600: non-root users cannot open it, so cannot lock it or freeze daemon
    static let lockFile = "firewall.lock"
}

/// Output of a single command
struct Output: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var succeeded: Bool { status == 0 }
}

/// Answers: external dependencies needed by a round — directory of the two files, current moment, executing a system command, lock timeout.
/// Subbed in tests; `live` uses real system.
struct FirewallSystem: Sendable {
    var directory: URL
    var moment: @Sendable () -> Moment
    var now: @Sendable () -> Date
    var run: @Sendable (_ executable: String, _ arguments: [String], _ input: String?) -> Output
    /// Maximum wait for lock. Only root can open lock, held only by another round or command; each subcommand has a timeout, so round will always end.
    /// Worst-case 9 subcommands per round (2 reads, 2 actions, 1 re-read after -E, 4 verifications), each up to `commandTimeout` + 1s, ~54s.
    var lockTimeout: TimeInterval = 60

    static let live = FirewallSystem(directory: FirewallPaths.directory, moment: liveMoment, now: { Date() },
                                       run: { runProcess($0, $1, $2, timeout: commandTimeout) })

    /// `CLOCK_MONOTONIC_RAW`: advances across sleep, "not subject to frequency or time adjustments" (man page text; `CLOCK_MONOTONIC` lacks this guarantee), resets at boot
    /// (boot treats trial as off anyway). @see https://keith.github.io/xcode-man-pages/clock_gettime.3.html
    private static func liveMoment() -> Moment {
        Moment(bootSession: bootSession(), now: MonotonicTime(milliseconds: Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)))
    }

    /// `kern.bootsessionuuid`; `nil` if unreadable or empty; handled in `FirewallState.advance`
    private static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let session = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return session.isEmpty ? nil : session
    }

    /// Subcommand timeout. pfctl, ifconfig, launchctl normally finish in milliseconds; hung execution is treated as failure to avoid stalled rounds and rollback failures.
    static let commandTimeout: TimeInterval = 5

    /// stdout and stderr written to temporary files rather than pipes: if child hangs or produces large output, caller won't block reading pipe.
    static func runProcess(_ executable: String, _ arguments: [String], _ input: String?, timeout: TimeInterval) -> Output {
        guard let out = scratchFile(), let err = scratchFile() else { return Output(status: -1, stdout: "", stderr: "Cannot create temporary file") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        // Do not inherit caller environment: sudo preserves user's HOME, which would cause dig to read user-writable ~/.digrc
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = err
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Output(status: -1, stdout: "", stderr: "Failed to launch: \(error)") }
        // Rules are only a few KB, pipe buffer is sufficient; child early exit fails write (SIGPIPE ignored in main), continues waiting for exit code.
        do {
            if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            try stdin.fileHandleForWriting.close()
        } catch {
            FileHandle.standardError.write(Data("notchkeeper-firewall: Failed to write to stdin of \(executable): \(error)\n".utf8))
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return Output(status: -1, stdout: "", stderr: "Timed out after \(timeout)s, terminated")
        }
        // Child and caller share same open file; seek to start to read after write. Read failure treated as error: empty output would look like empty anchor.
        let read = { (h: FileHandle) throws in
            try h.seek(toOffset: 0)
            return String(decoding: try h.readToEnd() ?? Data(), as: UTF8.self)
        }
        do {
            return Output(status: p.terminationStatus, stdout: try read(out), stderr: try read(err))
        } catch {
            return Output(status: -1, stdout: "", stderr: "Failed to read output: \(error)")
        }
    }

    /// Temporary file unlinked immediately after creation, keeping only fd. $TMPDIR during osascript privilege escalation might be user directory:
    /// `O_EXCL | O_NOFOLLOW` prevents following pre-existing symlinks, and unlinking prevents replacement or external reading.
    private static func scratchFile() -> FileHandle? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("notchkeeper-firewall-\(UUID().uuidString)").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        unlink(path)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Answers: how to write files so readers always observe a complete copy with proper permissions from the very first byte.
/// Creates temporary file in same directory with `O_CREAT | O_EXCL` and `mode`, then `rename(2)`.
/// Caller holds lock so only one writer runs at a time; fixed temp name ensures orphaned files from prior crashes are replaced, avoiding accumulation.
enum AtomicFile {
    static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        unlink(tmp.path)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(tmp.path)
            throw error
        }
    }
}
