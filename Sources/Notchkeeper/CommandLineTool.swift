import Foundation
import GuardCore

/// 回答：命令行工具 pipctl 装在哪、在不在 PATH 上。
/// App 每次启动把包里的 pipctl 换进 `bin/`，终端插件和用户的脚本都调它；
/// `~/.local/bin` 里的链接只在用户点了才建，占了的名字不碰。不改 `~/.zshrc`、不读 PATH（CLAUDE.md 硬规则）
enum CommandLineTool {
    static let installed = GuardPaths.directory.appendingPathComponent("bin/pipctl")
    /// 不少 shell 配置已经把它放进 PATH（XDG 的用户可执行目录）
    static let link = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/pipctl")

    enum LinkState: Equatable {
        case linked, absent
        /// 这个名字已经是别的文件，或指向别处的链接
        case occupied
    }

    /// App 启动时：换成包里这一版；找不到就留着上次装的
    static func install() {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "pipctl") else { return }
        do {
            try FileManager.default.replaceItem(at: installed, withCopyOf: bundled)
        } catch {
            Log.write("pipctl：装不上：\(error.localizedDescription)")
        }
    }

    static func linkState(_ link: URL = link, target: URL = installed) -> LinkState {
        do {
            return try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path ? .linked : .occupied
        } catch {
            // 不存在，或不是符号链接（普通文件、目录）：看有没有东西
            var info = stat()
            return lstat(link.path, &info) == 0 ? .occupied : .absent
        }
    }

    static func createLink(_ link: URL = link, target: URL = installed) throws {
        guard linkState(link, target: target) == .absent else { throw occupied(link) }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        Log.write("pipctl：已链接到 ~/.local/bin")
    }

    /// 已经没有了就什么都不做
    static func removeLink(_ link: URL = link, target: URL = installed) throws {
        switch linkState(link, target: target) {
        case .absent: return
        case .occupied: throw occupied(link)
        case .linked: try FileManager.default.removeItem(at: link)
        }
        Log.write("pipctl：已移除 ~/.local/bin 里的链接")
    }

    private static func occupied(_ link: URL) -> Failure {
        Failure(errorDescription: String(localized: "\(link.path) 已经是别的文件，不覆盖"))
    }
}
