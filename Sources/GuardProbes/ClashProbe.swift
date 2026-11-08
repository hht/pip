import Darwin

/// Answers: whether the Clash core process is running.
/// The result only determines healthy vs. unknown; it does not verdict violated (see `EgressGuard` for rules).
/// Matches exact executable name, not substring grep: when GUI (`clash-verge`) and privileged service (`clash-verge-service`)
/// are running but the core has not started, traffic does not go through Clash.
public enum ClashProbe {
    /// Clash core name bundled with Clash Verge Rev (verified). Add others based on testing if switching Clash variants.
    static let coreNames: Set<String> = ["verge-mihomo"]

    /// Returns nil (unknown) when process list cannot be enumerated, not treated as "not running".
    public static func current() -> Bool? {
        executablePaths().map(isRunning(executablePaths:))
    }

    static func isRunning(executablePaths: [String]) -> Bool {
        executablePaths.contains { coreNames.contains(String($0.split(separator: "/").last ?? "")) }
    }

    /// @see https://opensource.apple.com/source/xnu/xnu-7195.81.3/libsyscall/wrappers/libproc/libproc.h
    private static func executablePaths() -> [String]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(count)).compactMap { pid in
            proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        }
    }
}
