import Foundation

/// 回答：内核把去往公网的流量交给哪个网卡。
/// 不看默认路由，也不看 SCDynamicStore 的 PrimaryInterface：Clash Verge 的 TUN 模式用 `1/8`、`16/4`、
/// `128.0/1` 等更具体的路由把流量导进 utun，默认路由和主网卡仍是 en0（Clash Verge TUN 开着时实测，
/// macOS 26.5）。
/// @see https://keith.github.io/xcode-man-pages/route.8.html  `route -n get <dest>` 打印内核为该地址选的路由
public enum RouteProbe {
    /// 只查本机路由表，不发包。第一个是 Anthropic 公布的入站网段 160.79.104.0/23 里的地址，
    /// 第一个直接回答「去 Claude 的路由走哪」；另两个是不同网段的公网地址。
    /// 三者同权：任何一个不走 utun 都判 violated（除局域网外全部流量必须走代理，docs/egress-guard.md）。
    /// Clash 的 DIRECT 规则不改内核路由表；只有 TUN 排除了某网段，这里才会看到 en0，那本身就违反规则。
    /// @see https://docs.anthropic.com/en/api/ip-addresses
    static let destinations = ["160.79.104.10", "1.1.1.1", "8.8.8.8"]

    /// 取 `interface:` 那一行；没有就是查不到。
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

    /// 多个目的地合成一个结果：任何一个不走 utun 就报它（最坏情况优先），全查不到才是未知。
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

    /// 跑一个子进程，正常退出且状态码 0 时返回 stdout，否则 `nil`。
    /// 调用方的任务被取消（一轮超时）时 `terminate` 子进程；已取消时不再启动。
    /// 启动和结束放在同一把锁里，避免对还没启动的 `Process` 调 `terminate`（会抛 ObjC 异常）。
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

    /// `Process` 不是 Sendable；所有对它的跨线程访问都经过 `lock`。
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
            let data = stdout.fileHandleForReading.readDataToEndOfFile() // 输出只有几行，读到 EOF 再等退出不会死锁
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
