import Foundation
import GuardCore

/// 回答：以前单独装的守卫后台进程 guardd（用户级 LaunchAgent）怎么卸掉。
/// 守卫并进 App 之后它没用了，留着还会每 5 秒探一次网络。App 每次启动看一眼：plist 在就卸下 LaunchAgent，
/// 卸下来了才删 plist、二进制和它写的状态文件；卸不下来什么都不删，下次启动再试。日志和安装备份留着。
/// 不要 sudo：LaunchAgent 在当前用户的 `gui/<uid>` 域里。等所有装过 guardd 的机器都启动过一次新版，这个文件可以删掉。
/// @see https://keith.github.io/xcode-man-pages/launchctl.1.html （bootout、print）
enum LegacyGuardd {
    static let label = "com.notchkeeper.guardd"

    struct Files {
        var plist: URL
        var binary: URL
        var state: URL

        static let live = Files(
            plist: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist"),
            binary: GuardPaths.directory.appendingPathComponent("bin/guardd"),
            state: GuardPaths.directory.appendingPathComponent("guard-state.json"))
    }

    /// launchctl 的两个动作，测试换成假的
    struct Launchd {
        var bootout: () -> Void
        var isLoaded: () -> Bool
        /// 两次查询之间等一会儿
        var wait: () -> Void

        static let live = Launchd(
            bootout: { _ = launchctl("bootout", "\(domain)/\(label)") },
            isLoaded: { launchctl("print", "\(domain)/\(label)") == 0 },
            wait: { Thread.sleep(forTimeInterval: 1) })

        private static var domain: String { "gui/\(getuid())" }

        /// 退出码；启动不了算 -1。输出丢掉：print 会打出整份 job 描述
        private static func launchctl(_ args: String...) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
    }

    /// 会等 launchctl，别在主线程上调
    static func remove(_ files: Files = .live, launchd: Launchd = .live, log: (String) -> Void = Log.write) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: files.plist.path) else { return }
        if launchd.isLoaded() {
            launchd.bootout()
            // guardd 收到 SIGTERM 在当前一步结束时退出，最长等一轮的截止时间
            var waits = 0
            while launchd.isLoaded(), waits < 10 {
                launchd.wait()
                waits += 1
            }
            guard !launchd.isLoaded() else {
                return log("旧的守卫后台进程 guardd 卸不下来，下次启动再试；文件都没删")
            }
        }
        for url in [files.plist, files.binary, files.state] {
            do {
                try fm.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // 早就没有了
            } catch {
                log("删旧的守卫文件 \(url.lastPathComponent) 失败：\(error.localizedDescription)")
            }
        }
        log("守卫已并进 App：卸掉了旧的后台进程 guardd")
    }
}
