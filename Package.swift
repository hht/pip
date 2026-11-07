// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notchkeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchkeeper",
            dependencies: ["AgentCore", "FirewallCore", "GuardCore", "GuardProbes", "MascotCore", "NotchCore", "PluginCore", "PluginStore"],
            path: "Sources/Notchkeeper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // App 外壳里离不开 AppKit、SwiftUI 或真文件的部分（config.json 读写、Ghostty 跳转、mod 安装、视图量高度等）
        .testTarget(name: "NotchkeeperTests", dependencies: ["Notchkeeper"]),
        // 出口守卫的纯逻辑（判定、每轮结果的格式）：不 import SwiftUI / AppKit，不做 I/O
        .target(name: "GuardCore"),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
        // 出口守卫在 App 里的检查：各路观测（路由、Clash 进程、出口 IP、网络路径）的 I/O 和边界解析，
        // 以及每 5 秒一轮的编排（`GuardMonitor`）。判定交给 GuardCore
        .target(name: "GuardProbes", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardProbesTests", dependencies: ["GuardProbes"]),
        // 防火墙的纯逻辑（docs/firewall.md）：开启 / 保留 / 关闭怎么改状态、每一轮该对 pf 做什么、规则长什么样、核对结果、root 状态文件和状态摘要的格式，
        // 以及放行表从 Clash 配置和 GeoIP 库里怎么算。
        // 纯值类型，不调 pfctl、不读文件、不取时钟
        .target(name: "FirewallCore"),
        .testTarget(name: "FirewallCoreTests", dependencies: ["FirewallCore"]),
        // 防火墙的特权辅助程序（装成 /Library/PrivilegedHelperTools/notchkeeper-firewall，root 跑）：LaunchDaemon 开着时每 10 秒跑一轮、关着时不跑，
        // App 用 osascript 带管理员权限调开启 / 保留 / 关闭。只做 I/O：调 pfctl 和 dig、读 Clash Verge 目录、读写 root 目录里的文件、加锁、取时钟；判定在 FirewallCore
        .executableTarget(name: "firewalld", dependencies: ["FirewallCore"]),
        .testTarget(name: "firewalldTests", dependencies: ["firewalld", "FirewallCore"]),
        // Pip 此刻是什么造型、做什么动作：造型数据、眼形补间、球面位置、动作编排（[Track]）、空闲调度、犯困 / 回正 / 晕的时钟、跟随鼠标。纯值类型，只依赖 CoreGraphics
        .target(name: "MascotCore"),
        .testTarget(name: "MascotCoreTests", dependencies: ["MascotCore"]),
        // App 图标：按 MascotCore 的造型数据画 Pip，输出 iconset（run.sh 用 iconutil 合成 AppIcon.icns）
        .executableTarget(name: "mascot-icon", dependencies: ["MascotCore"]),
        // Claude Code 会话此刻在什么状态、回合什么时候结束：解析 ~/.claude/sessions/<pid>.json、跟踪回合（docs/agent-integration.md）。纯值类型，不读目录、不查进程
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        // 卡上写什么、刘海此刻放哪张卡、放多久、放出来时响不响：红卡一层 + 临时卡队列（docs/ui.md「卡片」）；守卫读数画成什么、红卡挂上还是撤掉（docs/egress-guard.md）；
        // 各插件多急、收起时谁上位、面板一行画什么；刘海三种形态各多大；config.json 有哪些设置。纯值类型，不知道卡长什么样、不放声音、不起定时器
        .target(name: "NotchCore", dependencies: ["AgentCore", "GuardCore", "MascotCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "AgentCore", "GuardCore", "MascotCore"]),
        // 外部插件发来的一条消息合不合法、变成哪张卡或面板里哪一行：解析收件箱里的消息和插件登记、限流、过期，跟踪活动。纯值类型，不读目录
        .target(name: "PluginCore", dependencies: ["GuardCore", "NotchCore"]),
        .testTarget(name: "PluginCoreTests", dependencies: ["PluginCore", "NotchCore"]),
        // 插件目录里装了哪些插件、怎么装进去、卸掉、新建（App 设置页和 `pipctl plugin` 共用）。只做文件 I/O，合不合规归 PluginCore
        .target(name: "PluginStore", dependencies: ["NotchCore", "PluginCore"]),
        .testTarget(name: "PluginStoreTests", dependencies: ["PluginStore", "PluginCore"]),
        // 外部插件的命令行：`pipctl notify …`、`pipctl send` 把一张卡写进收件箱（先写 tmp/ 再 rename 到 new/），格式由 PluginCore 校验
        .executableTarget(name: "pipctl", dependencies: ["NotchCore", "PluginCore", "PluginStore"]),
        .testTarget(name: "pipctlTests", dependencies: ["pipctl", "PluginCore", "NotchCore"]),
        // 终端插件（Resources/plugins/terminal/notchkeeper.zsh）：用真的 zsh 跑，假的 pipctl 记下参数
        .testTarget(name: "TerminalPluginTests"),
    ]
)
