import Foundation

/// Answers: which network interface the kernel directs public internet traffic to.
/// Does not check default routes, nor SCDynamicStore's PrimaryInterface: Clash Verge's TUN mode uses more specific routes
/// like `1/8`, `16/4`, `128.0/1` to direct traffic into utun, while the default route and primary interface remain en0 (verified
/// with Clash Verge TUN enabled on macOS 26.5).
/// @see https://keith.github.io/xcode-man-pages/route.8.html  `route -n get <dest>` prints the kernel's selected route for the address
public enum RouteProbe {
    /// Only checks local kernel routing table, sends no packets. The first is within Anthropic's published inbound range 160.79.104.0/23,
    /// directly answering "which route does Claude traffic take"; the other two are public addresses in different subnets.
    /// All three carry equal weight: if any one does not route via utun, it is judged violated (all non-LAN traffic must go through proxy, docs/egress-guard.md).
    /// Clash's DIRECT rule does not modify the kernel routing table; only when TUN excludes a subnet would en0 appear here, which itself violates policy.
    /// @see https://docs.anthropic.com/en/api/ip-addresses
    static let destinations = ["160.79.104.10", "1.1.1.1", "8.8.8.8"]

    /// Extracts the `interface:` line; absent means not found.
    static func parseInterface(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" {
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    /// Combines multiple destinations into one result: reports any interface not routing via utun (worst case priority); only unknown if all fail.
    static func combine(_ interfaces: [String?]) -> String? {
        let known = interfaces.compactMap { $0 }
        return known.first { !$0.hasPrefix("utun") } ?? known.first
    }

    public static func current() async -> String? {
        var interfaces: [String?] = []
        for destination in destinations {
            let output = await self.output(of: URL(fileURLWithPath: "/sbin/route"), arguments: ["-n", "get", destination])
            interfaces.append(output.flatMap(parseInterface))
        }
        return combine(interfaces)
    }

    /// Runs a child process; returns stdout if exited normally with status code 0, otherwise `nil`.
    /// Terminates child process when caller's task is cancelled (round timeout); does not launch if already cancelled.
    /// Launch and termination share the same lock to avoid calling `terminate` on an unlaunched `Process` (throws ObjC exception).
    /// @see https://developer.apple.com/documentation/foundation/process/terminate()
    static func output(of executable: URL, arguments: [String]) async -> String? {
        let child = Child(executable: executable, arguments: arguments)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: child.run()) }
            }
        } onCancel: {
            child.cancel()
        }
    }

    /// `Process` is not Sendable; all cross-thread access goes through `lock`.
    private final class Child: @unchecked Sendable {
        private let process = Process()
        private let stdout = Pipe()
        private let lock = NSLock()
        private var cancelled = false

        init(executable: URL, arguments: [String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
        }

        func run() -> String? {
            let launched = lock.withLock {
                guard !cancelled else { return false }
                do { try process.run() } catch { return false }
                return true
            }
            guard launched else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile() // Output is only a few lines; reading to EOF before waiting for exit avoids deadlock
            process.waitUntilExit()
            let ok = process.terminationReason == .exit && process.terminationStatus == 0
            return ok ? String(decoding: data, as: UTF8.self) : nil
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if process.isRunning { process.terminate() }
            }
        }
    }
}
