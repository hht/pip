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
        // Parts of the App shell dependent on AppKit, SwiftUI, or real files (config.json I/O, Ghostty jump, mod install, view measurements, etc.)
        .testTarget(name: "NotchkeeperTests", dependencies: ["Notchkeeper"]),
        // Pure logic for egress guard (verdicts, round result formats): does not import SwiftUI / AppKit, performs no I/O
        .target(name: "GuardCore"),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
        // Egress guard checks in App: I/O and boundary parsing across observations (routes, Clash process, egress IP, network paths),
        // and 5-second round orchestration (GuardMonitor). Verdicts delegated to GuardCore
        .target(name: "GuardProbes", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardProbesTests", dependencies: ["GuardProbes"]),
        // Pure logic for firewall (docs/firewall.md): state transitions for enable / keep / disable, pf actions per round, rule definitions, check results,
        // formats for root state file and status summary, and allow table computation from Clash config and GeoIP database.
        // Pure value types, invokes no pfctl, reads no files, accesses no clocks
        .target(name: "FirewallCore"),
        .testTarget(name: "FirewallCoreTests", dependencies: ["FirewallCore"]),
        // Privileged helper tool for firewall (installed as /Library/PrivilegedHelperTools/notchkeeper-firewall, runs as root): runs every 10s when LaunchDaemon active, inactive when off;
        // App invokes enable / keep / disable via osascript with admin privileges. Performs I/O only: invokes pfctl and dig, reads Clash Verge directory, reads/writes root directory files, acquires locks, accesses clocks; verdicts in FirewallCore
        .executableTarget(name: "firewalld", dependencies: ["FirewallCore"]),
        .testTarget(name: "firewalldTests", dependencies: ["firewalld", "FirewallCore"]),
        // Current Pip look and motion: look data, eye morphing, spherical coordinates, choreography ([Track]), idle dispatching, clocks (sleepiness / recentering / dizziness), gaze tracking. Pure value types, depends on CoreGraphics only
        .target(name: "MascotCore"),
        .testTarget(name: "MascotCoreTests", dependencies: ["MascotCore"]),
        // App icon: renders Pip from MascotCore look data, outputs iconset (run.sh synthesizes AppIcon.icns via iconutil)
        .executableTarget(name: "mascot-icon", dependencies: ["MascotCore"]),
        // Claude Code session state and turn completion tracking: parses ~/.claude/sessions/<pid>.json, tracks turns (docs/agent-integration.md). Pure value types, reads no directories, checks no processes
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        // Card content, active notch card selection, duration, and sound cues: red card layer + temporary card queue (docs/ui.md "Cards"); guard reading presentation, attaching/dismissing red card (docs/egress-guard.md);
        // plugin urgencies, collapsed lead selection, panel row rendering; dimensions for three notch states; config.json settings. Pure value types, unaware of card visuals, plays no audio, spawns no timers
        .target(name: "NotchCore", dependencies: ["AgentCore", "GuardCore", "MascotCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "AgentCore", "GuardCore", "MascotCore"]),
        // Validity of external plugin messages, card conversion, and panel row mapping: parses inbox messages and plugin manifests, handles rate limiting, expiration, and activity tracking. Pure value types, reads no directories
        .target(name: "PluginCore", dependencies: ["GuardCore", "NotchCore"]),
        .testTarget(name: "PluginCoreTests", dependencies: ["PluginCore", "NotchCore"]),
        // Installed plugins management, installation, uninstallation, creation (shared between App Settings and pipctl plugin). File I/O only, validation delegated to PluginCore
        .target(name: "PluginStore", dependencies: ["NotchCore", "PluginCore"]),
        .testTarget(name: "PluginStoreTests", dependencies: ["PluginStore", "PluginCore"]),
        // External plugin CLI: pipctl notify …, pipctl send writes a card to inbox (writes to tmp/ then renames to new/), format validated by PluginCore
        .executableTarget(name: "pipctl", dependencies: ["NotchCore", "PluginCore", "PluginStore"]),
        .testTarget(name: "pipctlTests", dependencies: ["pipctl", "PluginCore", "NotchCore"]),
        // Terminal plugin (Resources/plugins/terminal/pip.zsh): runs in real zsh, mock pipctl records arguments
        .testTarget(name: "TerminalPluginTests"),
    ]
)
