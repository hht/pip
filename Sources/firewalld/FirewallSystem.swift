import Darwin
import Foundation
import FirewallCore

/// 装在哪、叫什么。和 scripts/firewall-rescue.sh、install-firewall.sh、firewall-drill.sh 里的一致（包括 AtomicFile 的临时文件名），改了四处一起改
enum FirewallPaths {
    static let label = "com.notchkeeper.firewall"
    static let anchor = "com.apple/300.Notchkeeper"
    /// root 0755：普通用户进程不能在里面写文件，也就伪造不了状态和状态摘要（docs/firewall.md §4）
    static let directory = URL(fileURLWithPath: "/Library/Application Support/Notchkeeper")
    /// 一轮和命令互斥用。root 0600：普通用户打不开，也就锁不住它、卡不死守护进程
    static let lockFile = "firewall.lock"
}

/// 一次命令输出
struct Output: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var succeeded: Bool { status == 0 }
}

/// 回答：一轮要用到的外部世界——两个文件所在的目录、此刻、跑一条系统命令、等锁最多多久。测试换成假的，`live` 是真的
struct FirewallSystem: Sendable {
    var directory: URL
    var moment: @Sendable () -> Moment
    var now: @Sendable () -> Date
    var run: @Sendable (_ executable: String, _ arguments: [String], _ input: String?) -> Output
    /// 拿锁最多等多久。锁只有 root 打得开，只会被另一轮或另一条命令拿着；每条子命令有上限，一轮总会结束。
    /// 一轮最坏 9 条子命令（读 2 条、动作 2 条、-E 后再读 1 条、核对 4 条），每条最多 `commandTimeout` + 1 秒，约 54 秒
    var lockTimeout: TimeInterval = 60

    static let live = FirewallSystem(directory: FirewallPaths.directory, moment: liveMoment, now: { Date() },
                                       run: { runProcess($0, $1, $2, timeout: commandTimeout) })

    /// `CLOCK_MONOTONIC_RAW`：睡眠也走，「不受频率和时间调整影响」（man page 原话；`CLOCK_MONOTONIC` 没这么写），开机归零
    /// （开机本来就把 trial 当 off）。@see https://keith.github.io/xcode-man-pages/clock_gettime.3.html
    private static func liveMoment() -> Moment {
        Moment(bootSession: bootSession(), now: MonotonicTime(milliseconds: Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)))
    }

    /// `kern.bootsessionuuid`；读不出来（或读出空串）是 `nil`，怎么办见 `FirewallState` 的 `advance`
    private static func bootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let session = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return session.isEmpty ? nil : session
    }

    /// 子命令最多跑多久。pfctl、ifconfig、launchctl 正常都在毫秒级；卡住的那次当失败，免得一轮不结束、试运行不回滚
    static let commandTimeout: TimeInterval = 5

    /// stdout、stderr 写进临时文件而不是管道：子进程卡住或输出很多时，这边都不会跟着卡在读管道上
    static func runProcess(_ executable: String, _ arguments: [String], _ input: String?, timeout: TimeInterval) -> Output {
        guard let out = scratchFile(), let err = scratchFile() else { return Output(status: -1, stdout: "", stderr: "建不了临时文件") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        // 不继承调用方的环境：sudo 会保留用户的 HOME，dig 就会读用户可写的 ~/.digrc
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = err
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Output(status: -1, stdout: "", stderr: "起不来：\(error)") }
        // 规则只有几 KB，管道缓冲装得下；子进程提前退出时写会失败（SIGPIPE 已在 main 里忽略），照样往下等它的退出码
        do {
            if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            try stdin.fileHandleForWriting.close()
        } catch {
            FileHandle.standardError.write(Data("notchkeeper-firewall: 写 \(executable) 的 stdin 失败：\(error)\n".utf8))
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return Output(status: -1, stdout: "", stderr: "超过 \(timeout) 秒没结束，已结束它")
        }
        // 子进程和这边共用同一个打开的文件，写完偏移在末尾，从头读。读不出当失败：当成「成功、没输出」会被认成 anchor 是空的
        let read = { (h: FileHandle) throws in
            try h.seek(toOffset: 0)
            return String(decoding: try h.readToEnd() ?? Data(), as: UTF8.self)
        }
        do {
            return Output(status: p.terminationStatus, stdout: try read(out), stderr: try read(err))
        } catch {
            return Output(status: -1, stdout: "", stderr: "读不出输出：\(error)")
        }
    }

    /// 新建就删掉、只留 fd 的临时文件。$TMPDIR 在 osascript 提权时可能是用户目录（推断）：`O_EXCL | O_NOFOLLOW`
    /// 不跟着别人事先放好的符号链接写，删掉之后别人也换不掉、读不到它
    private static func scratchFile() -> FileHandle? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("notchkeeper-firewall-\(UUID().uuidString)").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        unlink(path)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// 回答：怎么写文件，让读的一方永远只看到完整的一份、从第一个字节起就是该有的权限。
/// 同目录临时文件 `O_CREAT | O_EXCL` 按 `mode` 新建，再 `rename(2)`。
/// 调用方拿着锁，同一时刻只有一个写的，所以临时文件用固定名字：上次崩在半路留下的下次就被清掉，不越积越多
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
